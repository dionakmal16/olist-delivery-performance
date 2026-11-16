/* =====================================================================
   OLIST DELIVERY PERFORMANCE  |  01 - SETUP (SQL Server, T-SQL)
   Memuat 8 CSV hasil python/clean_olist.py ke database OlistDB:
   staging (teks) -> tabel bertipe dengan PRIMARY KEY dan FOREIGN KEY.

   Butuh SQL Server 2017+ (BULK INSERT ... FORMAT = 'CSV').
   Jalankan per bagian di SSMS. Ubah @path jika folder Anda berbeda
   (BULK INSERT tidak bisa memakai variabel, jadi path ditulis langsung
   di setiap perintah; cari-dan-ganti "C:\data\portofolio_2\clean\").
   ===================================================================== */


/* =====================================================================
   PART 0 - DATABASE
   ===================================================================== */
IF DB_ID('OlistDB') IS NULL CREATE DATABASE OlistDB;
GO
USE OlistDB;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO


/* =====================================================================
   PART 1 - STAGING (semua kolom teks)
   Kenapa teks dulu? Satu nilai yang tidak sesuai tipe akan menggagalkan
   seluruh BULK INSERT. Dengan staging teks, load pasti berhasil, lalu
   konversi tipe dilakukan terkontrol dengan TRY_CAST di PART 2.
   ===================================================================== */
DROP TABLE IF EXISTS stg.geolocation_zip, stg.customers, stg.sellers, stg.products,
                     stg.orders, stg.order_items, stg.order_payments, stg.order_reviews;
GO
CREATE TABLE stg.geolocation_zip (zip_code_prefix NVARCHAR(10), lat NVARCHAR(40), lng NVARCHAR(40),
    city NVARCHAR(100), state NVARCHAR(10), n_points NVARCHAR(20));
CREATE TABLE stg.customers (customer_id NVARCHAR(50), customer_unique_id NVARCHAR(50),
    customer_zip_code_prefix NVARCHAR(10), customer_city NVARCHAR(100), customer_state NVARCHAR(10),
    customer_lat NVARCHAR(40), customer_lng NVARCHAR(40));
CREATE TABLE stg.sellers (seller_id NVARCHAR(50), seller_zip_code_prefix NVARCHAR(10),
    seller_city NVARCHAR(100), seller_state NVARCHAR(10), seller_lat NVARCHAR(40), seller_lng NVARCHAR(40));
CREATE TABLE stg.products (product_id NVARCHAR(50), product_category_name NVARCHAR(100),
    product_name_length NVARCHAR(20), product_description_length NVARCHAR(20), product_photos_qty NVARCHAR(20),
    product_weight_g NVARCHAR(20), product_length_cm NVARCHAR(20), product_height_cm NVARCHAR(20),
    product_width_cm NVARCHAR(20), product_category_name_english NVARCHAR(100));
CREATE TABLE stg.orders (order_id NVARCHAR(50), customer_id NVARCHAR(50), order_status NVARCHAR(20),
    order_purchase_timestamp NVARCHAR(30), order_approved_at NVARCHAR(30),
    order_delivered_carrier_date NVARCHAR(30), order_delivered_customer_date NVARCHAR(30),
    order_estimated_delivery_date NVARCHAR(30),
    flag_carrier_before_purchase NVARCHAR(10), flag_delivered_before_carrier NVARCHAR(10),
    flag_delivered_no_date NVARCHAR(10), flag_date_but_not_delivered NVARCHAR(10), flag_no_items NVARCHAR(10),
    approval_hours NVARCHAR(20), seller_handling_days NVARCHAR(20), carrier_transit_days NVARCHAR(20),
    total_delivery_days NVARCHAR(20), estimated_days NVARCHAR(20), delay_days NVARCHAR(20),
    is_late NVARCHAR(10), is_delivered NVARCHAR(10), purchase_month NVARCHAR(10), in_analysis_window NVARCHAR(10));
CREATE TABLE stg.order_items (order_id NVARCHAR(50), order_item_id NVARCHAR(10), product_id NVARCHAR(50),
    seller_id NVARCHAR(50), shipping_limit_date NVARCHAR(30), price NVARCHAR(20), freight_value NVARCHAR(20),
    flag_free_freight NVARCHAR(10), distance_km NVARCHAR(20));
CREATE TABLE stg.order_payments (order_id NVARCHAR(50), payment_sequential NVARCHAR(10),
    payment_type NVARCHAR(30), payment_installments NVARCHAR(10), payment_value NVARCHAR(20),
    flag_zero_payment NVARCHAR(10));
CREATE TABLE stg.order_reviews (review_id NVARCHAR(50), order_id NVARCHAR(50), review_score NVARCHAR(5),
    review_comment_title NVARCHAR(500), review_comment_message NVARCHAR(4000),
    review_creation_date NVARCHAR(30), review_answer_timestamp NVARCHAR(30), has_comment NVARCHAR(10));
GO

/* FORMAT = 'CSV' memahami tanda kutip, termasuk komentar ulasan yang berisi koma
   atau baris baru. CODEPAGE 65001 = UTF-8 (huruf Portugis seperti ã, ç).        */
BULK INSERT stg.geolocation_zip FROM 'C:\data\portofolio_2\clean\geolocation_zip_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.customers FROM 'C:\data\portofolio_2\clean\customers_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.sellers FROM 'C:\data\portofolio_2\clean\sellers_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.products FROM 'C:\data\portofolio_2\clean\products_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.orders FROM 'C:\data\portofolio_2\clean\orders_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.order_items FROM 'C:\data\portofolio_2\clean\order_items_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.order_payments FROM 'C:\data\portofolio_2\clean\order_payments_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
BULK INSERT stg.order_reviews FROM 'C:\data\portofolio_2\clean\order_reviews_clean.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', TABLOCK);
GO

-- CHECK: harus sama dengan output Python
-- geolocation_zip 19010 | customers 99441 | sellers 3095 | products 32951
-- orders 99441 | order_items 112650 | order_payments 103886 | order_reviews 98673
SELECT 'geolocation_zip' AS tbl, COUNT(*) AS n FROM stg.geolocation_zip UNION ALL
SELECT 'customers', COUNT(*) FROM stg.customers UNION ALL
SELECT 'sellers', COUNT(*) FROM stg.sellers UNION ALL
SELECT 'products', COUNT(*) FROM stg.products UNION ALL
SELECT 'orders', COUNT(*) FROM stg.orders UNION ALL
SELECT 'order_items', COUNT(*) FROM stg.order_items UNION ALL
SELECT 'order_payments', COUNT(*) FROM stg.order_payments UNION ALL
SELECT 'order_reviews', COUNT(*) FROM stg.order_reviews;
GO


/* =====================================================================
   PART 2 - TABEL BERTIPE + PRIMARY KEY + FOREIGN KEY
   Urutan pembuatan mengikuti relasi: tabel "induk" (dimensi) dulu,
   baru tabel "anak" (transaksi) yang merujuk ke induknya.

   PRIMARY KEY : menjamin satu baris = satu entitas (tidak ada duplikat).
   FOREIGN KEY : menjamin setiap rujukan menunjuk ke baris yang benar-benar ada
                 (tidak ada item untuk order yang tidak ada).
   ===================================================================== */
DROP TABLE IF EXISTS dbo.order_reviews, dbo.order_payments, dbo.order_items, dbo.orders,
                     dbo.products, dbo.sellers, dbo.customers, dbo.geolocation_zip;
GO

CREATE TABLE dbo.geolocation_zip (
    zip_code_prefix CHAR(5)      NOT NULL CONSTRAINT PK_geolocation_zip PRIMARY KEY,
    lat             DECIMAL(9,6) NOT NULL,
    lng             DECIMAL(9,6) NOT NULL,
    city            NVARCHAR(100) NULL,
    state           CHAR(2)      NULL,
    n_points        INT          NULL
);

/* Catatan desain: customers dan sellers TIDAK diberi FOREIGN KEY ke geolocation_zip,
   karena 279 kode pos pelanggan dan 7 kode pos seller memang tidak ada di data
   geolokasi. Relasinya tetap bisa dipakai dengan LEFT JOIN.                       */
CREATE TABLE dbo.customers (
    customer_id              CHAR(32)      NOT NULL CONSTRAINT PK_customers PRIMARY KEY,
    customer_unique_id       CHAR(32)      NOT NULL,   -- orang yang sama bisa punya beberapa customer_id
    customer_zip_code_prefix CHAR(5)       NOT NULL,
    customer_city            NVARCHAR(100) NOT NULL,
    customer_state           CHAR(2)       NOT NULL,
    customer_lat             DECIMAL(9,6)  NULL,
    customer_lng             DECIMAL(9,6)  NULL
);

CREATE TABLE dbo.sellers (
    seller_id              CHAR(32)      NOT NULL CONSTRAINT PK_sellers PRIMARY KEY,
    seller_zip_code_prefix CHAR(5)       NOT NULL,
    seller_city            NVARCHAR(100) NOT NULL,
    seller_state           CHAR(2)       NOT NULL,
    seller_lat             DECIMAL(9,6)  NULL,
    seller_lng             DECIMAL(9,6)  NULL
);

CREATE TABLE dbo.products (
    product_id                    CHAR(32)      NOT NULL CONSTRAINT PK_products PRIMARY KEY,
    product_category_name         NVARCHAR(100) NOT NULL,
    product_category_name_english NVARCHAR(100) NOT NULL,
    product_name_length           INT NULL,
    product_description_length    INT NULL,
    product_photos_qty            INT NULL,
    product_weight_g              INT NULL,
    product_length_cm             INT NULL,
    product_height_cm             INT NULL,
    product_width_cm              INT NULL
);

CREATE TABLE dbo.orders (
    order_id                      CHAR(32)     NOT NULL CONSTRAINT PK_orders PRIMARY KEY,
    customer_id                   CHAR(32)     NOT NULL
        CONSTRAINT FK_orders_customers REFERENCES dbo.customers (customer_id),
    order_status                  VARCHAR(20)  NOT NULL,
    order_purchase_timestamp      DATETIME2(0) NOT NULL,
    order_approved_at             DATETIME2(0) NULL,
    order_delivered_carrier_date  DATETIME2(0) NULL,
    order_delivered_customer_date DATETIME2(0) NULL,
    order_estimated_delivery_date DATETIME2(0) NOT NULL,
    flag_carrier_before_purchase  BIT NOT NULL,
    flag_delivered_before_carrier BIT NOT NULL,
    flag_delivered_no_date        BIT NOT NULL,
    flag_date_but_not_delivered   BIT NOT NULL,
    flag_no_items                 BIT NOT NULL,
    approval_hours                DECIMAL(10,2) NULL,
    seller_handling_days          DECIMAL(10,2) NULL,
    carrier_transit_days          DECIMAL(10,2) NULL,
    total_delivery_days           DECIMAL(10,2) NULL,
    estimated_days                DECIMAL(10,2) NULL,
    delay_days                    INT NULL,
    is_late                       BIT NULL,
    is_delivered                  BIT NOT NULL,
    purchase_month                CHAR(7) NOT NULL,
    in_analysis_window            BIT NOT NULL
);

CREATE TABLE dbo.order_items (
    order_id            CHAR(32)      NOT NULL
        CONSTRAINT FK_items_orders REFERENCES dbo.orders (order_id),
    order_item_id       INT           NOT NULL,
    product_id          CHAR(32)      NOT NULL
        CONSTRAINT FK_items_products REFERENCES dbo.products (product_id),
    seller_id           CHAR(32)      NOT NULL
        CONSTRAINT FK_items_sellers REFERENCES dbo.sellers (seller_id),
    shipping_limit_date DATETIME2(0)  NOT NULL,
    price               DECIMAL(10,2) NOT NULL CONSTRAINT CK_items_price CHECK (price > 0),
    freight_value       DECIMAL(10,2) NOT NULL CONSTRAINT CK_items_freight CHECK (freight_value >= 0),
    flag_free_freight   BIT NOT NULL,
    distance_km         DECIMAL(10,1) NULL,
    CONSTRAINT PK_order_items PRIMARY KEY (order_id, order_item_id)   -- primary key gabungan
);

CREATE TABLE dbo.order_payments (
    order_id             CHAR(32)      NOT NULL
        CONSTRAINT FK_payments_orders REFERENCES dbo.orders (order_id),
    payment_sequential   INT           NOT NULL,
    payment_type         VARCHAR(20)   NOT NULL,
    payment_installments INT           NOT NULL,
    payment_value        DECIMAL(10,2) NOT NULL,
    flag_zero_payment    BIT NOT NULL,
    CONSTRAINT PK_order_payments PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE dbo.order_reviews (
    order_id                CHAR(32)       NOT NULL CONSTRAINT PK_order_reviews PRIMARY KEY
        CONSTRAINT FK_reviews_orders REFERENCES dbo.orders (order_id),
    review_id               CHAR(32)       NOT NULL,   -- tidak unik di data asli
    review_score            TINYINT        NOT NULL CONSTRAINT CK_reviews_score CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    NVARCHAR(500)  NULL,
    review_comment_message  NVARCHAR(4000) NULL,
    review_creation_date    DATETIME2(0)   NOT NULL,
    review_answer_timestamp DATETIME2(0)   NOT NULL,
    has_comment             BIT NOT NULL
);
GO

/* Pengisian mengikuti urutan induk -> anak (kalau terbalik, FOREIGN KEY menolak).
   TRY_CAST mengembalikan NULL jika konversi gagal, bukan error.
   Angka produk tertulis "40.0" di CSV, jadi dikonversi ke FLOAT dulu, baru ke INT. */
INSERT INTO dbo.geolocation_zip
SELECT zip_code_prefix, TRY_CAST(lat AS DECIMAL(9,6)), TRY_CAST(lng AS DECIMAL(9,6)),
       NULLIF(city, ''), NULLIF(state, ''), TRY_CAST(n_points AS INT)
FROM stg.geolocation_zip;

INSERT INTO dbo.customers
SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state,
       TRY_CAST(NULLIF(customer_lat, '') AS DECIMAL(9,6)), TRY_CAST(NULLIF(customer_lng, '') AS DECIMAL(9,6))
FROM stg.customers;

INSERT INTO dbo.sellers
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state,
       TRY_CAST(NULLIF(seller_lat, '') AS DECIMAL(9,6)), TRY_CAST(NULLIF(seller_lng, '') AS DECIMAL(9,6))
FROM stg.sellers;

INSERT INTO dbo.products
SELECT product_id, product_category_name, product_category_name_english,
       TRY_CAST(TRY_CAST(NULLIF(product_name_length, '') AS FLOAT) AS INT),
       TRY_CAST(TRY_CAST(NULLIF(product_description_length, '') AS FLOAT) AS INT),
       TRY_CAST(TRY_CAST(NULLIF(product_photos_qty, '') AS FLOAT) AS INT),
       TRY_CAST(TRY_CAST(NULLIF(product_weight_g, '') AS FLOAT) AS INT),
       TRY_CAST(TRY_CAST(NULLIF(product_length_cm, '') AS FLOAT) AS INT),
       TRY_CAST(TRY_CAST(NULLIF(product_height_cm, '') AS FLOAT) AS INT),
       TRY_CAST(TRY_CAST(NULLIF(product_width_cm, '') AS FLOAT) AS INT)
FROM stg.products;

INSERT INTO dbo.orders
SELECT order_id, customer_id, order_status,
       TRY_CAST(order_purchase_timestamp AS DATETIME2(0)),
       TRY_CAST(NULLIF(order_approved_at, '') AS DATETIME2(0)),
       TRY_CAST(NULLIF(order_delivered_carrier_date, '') AS DATETIME2(0)),
       TRY_CAST(NULLIF(order_delivered_customer_date, '') AS DATETIME2(0)),
       TRY_CAST(order_estimated_delivery_date AS DATETIME2(0)),
       TRY_CAST(flag_carrier_before_purchase AS BIT), TRY_CAST(flag_delivered_before_carrier AS BIT),
       TRY_CAST(flag_delivered_no_date AS BIT), TRY_CAST(flag_date_but_not_delivered AS BIT),
       TRY_CAST(flag_no_items AS BIT),
       TRY_CAST(NULLIF(approval_hours, '') AS DECIMAL(10,2)),
       TRY_CAST(NULLIF(seller_handling_days, '') AS DECIMAL(10,2)),
       TRY_CAST(NULLIF(carrier_transit_days, '') AS DECIMAL(10,2)),
       TRY_CAST(NULLIF(total_delivery_days, '') AS DECIMAL(10,2)),
       TRY_CAST(NULLIF(estimated_days, '') AS DECIMAL(10,2)),
       TRY_CAST(TRY_CAST(NULLIF(delay_days, '') AS FLOAT) AS INT),
       TRY_CAST(NULLIF(is_late, '') AS BIT),
       TRY_CAST(is_delivered AS BIT), purchase_month, TRY_CAST(in_analysis_window AS BIT)
FROM stg.orders;

INSERT INTO dbo.order_items
SELECT order_id, TRY_CAST(order_item_id AS INT), product_id, seller_id,
       TRY_CAST(shipping_limit_date AS DATETIME2(0)),
       TRY_CAST(price AS DECIMAL(10,2)), TRY_CAST(freight_value AS DECIMAL(10,2)),
       TRY_CAST(flag_free_freight AS BIT), TRY_CAST(NULLIF(distance_km, '') AS DECIMAL(10,1))
FROM stg.order_items;

INSERT INTO dbo.order_payments
SELECT order_id, TRY_CAST(payment_sequential AS INT), payment_type,
       TRY_CAST(payment_installments AS INT), TRY_CAST(payment_value AS DECIMAL(10,2)),
       TRY_CAST(flag_zero_payment AS BIT)
FROM stg.order_payments;

INSERT INTO dbo.order_reviews
SELECT order_id, review_id, TRY_CAST(review_score AS TINYINT),
       NULLIF(review_comment_title, ''), NULLIF(review_comment_message, ''),
       TRY_CAST(review_creation_date AS DATETIME2(0)), TRY_CAST(review_answer_timestamp AS DATETIME2(0)),
       TRY_CAST(has_comment AS BIT)
FROM stg.order_reviews;
GO


/* =====================================================================
   PART 3 - AUDIT LOAD: buktikan tidak ada data yang hilang atau rusak
   ===================================================================== */
-- CHECK 1: jumlah baris tabel bertipe = staging
SELECT 'orders' AS tbl, (SELECT COUNT(*) FROM stg.orders) AS staging, (SELECT COUNT(*) FROM dbo.orders) AS typed UNION ALL
SELECT 'order_items', (SELECT COUNT(*) FROM stg.order_items), (SELECT COUNT(*) FROM dbo.order_items) UNION ALL
SELECT 'order_payments', (SELECT COUNT(*) FROM stg.order_payments), (SELECT COUNT(*) FROM dbo.order_payments) UNION ALL
SELECT 'order_reviews', (SELECT COUNT(*) FROM stg.order_reviews), (SELECT COUNT(*) FROM dbo.order_reviews) UNION ALL
SELECT 'customers', (SELECT COUNT(*) FROM stg.customers), (SELECT COUNT(*) FROM dbo.customers) UNION ALL
SELECT 'sellers', (SELECT COUNT(*) FROM stg.sellers), (SELECT COUNT(*) FROM dbo.sellers) UNION ALL
SELECT 'products', (SELECT COUNT(*) FROM stg.products), (SELECT COUNT(*) FROM dbo.products) UNION ALL
SELECT 'geolocation_zip', (SELECT COUNT(*) FROM stg.geolocation_zip), (SELECT COUNT(*) FROM dbo.geolocation_zip);

-- CHECK 2: total uang sama dengan staging (konversi angka tidak membulatkan diam-diam)
SELECT SUM(TRY_CAST(price AS DECIMAL(12,2))) AS stg_price, (SELECT SUM(price) FROM dbo.order_items) AS typed_price
FROM stg.order_items;

-- CHECK 3: angka kunci, harus sama dengan ringkasan Python
-- 96203 order terkirim | terlambat 6.8% | rata-rata 12.5 hari
SELECT COUNT(*) AS delivered_orders,
       CAST(100.0 * AVG(CAST(is_late AS FLOAT)) AS DECIMAL(5,1)) AS late_pct,
       CAST(AVG(total_delivery_days) AS DECIMAL(5,1)) AS avg_delivery_days
FROM dbo.orders
WHERE is_delivered = 1 AND in_analysis_window = 1;
GO
