/* =====================================================================
   OLIST DELIVERY PERFORMANCE  |  02 - STAR SCHEMA (view untuk Power BI)
   Jalankan setelah 01_setup.sql.

   Star schema = tabel FAKTA di tengah (kejadian yang diukur: order, item)
   dikelilingi tabel DIMENSI (konteks: siapa, apa, di mana).
   Power BI paling efisien dan paling mudah dipahami jika modelnya berbentuk ini.

                       dim_product
                            |
     dim_customer -- fact_order_items -- dim_seller
           |                |
           +---------- fact_orders
                            |
                       dim_state (lewat customer_state / seller_state)
   ===================================================================== */
USE OlistDB;
GO


/* ---------------------------------------------------------------------
   Tabel referensi: nama dan wilayah 27 negara bagian Brasil.
   Data asli hanya berisi kode 2 huruf (SP, RJ, ...). Nama lengkap membuat
   peta di Power BI akurat, dan wilayah (region) berguna untuk agregasi.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dbo.dim_state;
CREATE TABLE dbo.dim_state (
    state      CHAR(2)       NOT NULL CONSTRAINT PK_dim_state PRIMARY KEY,
    state_name NVARCHAR(50)  NOT NULL,
    region     NVARCHAR(20)  NOT NULL
);
INSERT INTO dbo.dim_state (state, state_name, region) VALUES
('AC', N'Acre', N'North'), ('AP', N'Amapá', N'North'), ('AM', N'Amazonas', N'North'),
('PA', N'Pará', N'North'), ('RO', N'Rondônia', N'North'), ('RR', N'Roraima', N'North'),
('TO', N'Tocantins', N'North'),
('AL', N'Alagoas', N'Northeast'), ('BA', N'Bahia', N'Northeast'), ('CE', N'Ceará', N'Northeast'),
('MA', N'Maranhão', N'Northeast'), ('PB', N'Paraíba', N'Northeast'), ('PE', N'Pernambuco', N'Northeast'),
('PI', N'Piauí', N'Northeast'), ('RN', N'Rio Grande do Norte', N'Northeast'), ('SE', N'Sergipe', N'Northeast'),
('DF', N'Distrito Federal', N'Central-West'), ('GO', N'Goiás', N'Central-West'),
('MT', N'Mato Grosso', N'Central-West'), ('MS', N'Mato Grosso do Sul', N'Central-West'),
('ES', N'Espírito Santo', N'Southeast'), ('MG', N'Minas Gerais', N'Southeast'),
('RJ', N'Rio de Janeiro', N'Southeast'), ('SP', N'São Paulo', N'Southeast'),
('PR', N'Paraná', N'South'), ('RS', N'Rio Grande do Sul', N'South'), ('SC', N'Santa Catarina', N'South');
GO

-- CHECK: setiap kode negara bagian di data punya pasangan di dim_state (harus 0 baris)
SELECT DISTINCT customer_state AS missing_state FROM dbo.customers
WHERE customer_state NOT IN (SELECT state FROM dbo.dim_state)
UNION
SELECT DISTINCT seller_state FROM dbo.sellers
WHERE seller_state NOT IN (SELECT state FROM dbo.dim_state);
GO


/* ---------------------------------------------------------------------
   DIMENSI
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_dim_customer AS
SELECT c.customer_id,
       c.customer_unique_id,
       c.customer_city,
       c.customer_state,
       s.state_name AS customer_state_name,
       s.region     AS customer_region,
       c.customer_lat,
       c.customer_lng
FROM dbo.customers AS c
JOIN dbo.dim_state AS s ON s.state = c.customer_state;
GO

CREATE OR ALTER VIEW dbo.vw_dim_seller AS
SELECT se.seller_id,
       se.seller_city,
       se.seller_state,
       s.state_name AS seller_state_name,
       s.region     AS seller_region,
       se.seller_lat,
       se.seller_lng
FROM dbo.sellers AS se
JOIN dbo.dim_state AS s ON s.state = se.seller_state;
GO

CREATE OR ALTER VIEW dbo.vw_dim_product AS
SELECT p.product_id,
       p.product_category_name_english AS category,
       p.product_weight_g,
       p.product_length_cm * p.product_height_cm * p.product_width_cm AS product_volume_cm3,
       -- Kelas berat untuk analisis ongkir. Batasnya dipilih agar setiap kelas cukup terisi.
       CASE WHEN p.product_weight_g IS NULL  THEN 'Unknown'
            WHEN p.product_weight_g <  500   THEN '1. < 0.5 kg'
            WHEN p.product_weight_g <  2000  THEN '2. 0.5-2 kg'
            WHEN p.product_weight_g <  10000 THEN '3. 2-10 kg'
            ELSE '4. >= 10 kg' END AS weight_class
FROM dbo.products AS p;
GO


/* ---------------------------------------------------------------------
   FAKTA 1: satu baris per ORDER (grain = order)
   Dipakai untuk semua ukuran pengiriman: tepat waktu, durasi tiap tahap, rating.

   Kenapa nilai uang dirangkum dulu di CTE?
   Satu order bisa punya beberapa item DAN beberapa pembayaran. Jika
   order_items dan order_payments di-JOIN langsung ke orders bersamaan,
   barisnya berlipat (2 item x 2 pembayaran = 4 baris) dan total uang
   menjadi dobel. Ini disebut "fan-out". Solusinya: agregasi per order
   dulu, baru JOIN 1-ke-1.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_fact_orders AS
WITH item_totals AS (
    SELECT order_id,
           COUNT(*)                  AS item_count,
           COUNT(DISTINCT seller_id) AS seller_count,
           SUM(price)                AS items_value,
           SUM(freight_value)        AS freight_value,
           MAX(distance_km)          AS max_distance_km
    FROM dbo.order_items
    GROUP BY order_id
),
payment_totals AS (
    SELECT order_id,
           SUM(payment_value)        AS payment_value,
           MAX(payment_installments) AS max_installments
    FROM dbo.order_payments
    GROUP BY order_id
)
SELECT o.order_id,
       o.customer_id,
       o.order_status,
       CAST(o.order_purchase_timestamp AS DATE) AS purchase_date,
       o.order_purchase_timestamp,
       o.order_delivered_customer_date,
       o.order_estimated_delivery_date,
       o.approval_hours,
       o.seller_handling_days,
       o.carrier_transit_days,
       o.total_delivery_days,
       o.estimated_days,
       o.delay_days,
       o.is_late,
       o.is_delivered,
       o.in_analysis_window,
       -- Satu flag ringkas: order yang timestamp-nya janggal sebaiknya tidak dipakai menghitung durasi
       CAST(CASE WHEN o.flag_carrier_before_purchase = 1 OR o.flag_delivered_before_carrier = 1
                   OR o.flag_delivered_no_date = 1 OR o.flag_date_but_not_delivered = 1
                 THEN 1 ELSE 0 END AS BIT) AS has_date_anomaly,
       i.item_count,
       i.seller_count,
       i.items_value,
       i.freight_value,
       i.max_distance_km,
       p.payment_value,
       p.max_installments,
       r.review_score,
       r.has_comment
FROM dbo.orders AS o
LEFT JOIN item_totals    AS i ON i.order_id = o.order_id   -- LEFT: 775 order tidak punya item
LEFT JOIN payment_totals AS p ON p.order_id = o.order_id
LEFT JOIN dbo.order_reviews AS r ON r.order_id = o.order_id;
GO


/* ---------------------------------------------------------------------
   FAKTA 2: satu baris per ITEM (grain = item dalam order)
   Dipakai untuk analisis seller, kategori produk, dan ongkir.
   Info pengiriman diambil dari order induknya, karena satu order
   dikirim dan dinilai sebagai satu kesatuan.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_fact_order_items AS
SELECT oi.order_id,
       oi.order_item_id,
       o.customer_id,
       oi.seller_id,
       oi.product_id,
       CAST(o.order_purchase_timestamp AS DATE) AS purchase_date,
       oi.price,
       oi.freight_value,
       oi.distance_km,
       oi.flag_free_freight,
       -- Seller terlambat menyerahkan barang ke kurir (melewati batas shipping_limit_date)?
       CAST(CASE WHEN o.order_delivered_carrier_date IS NULL OR o.flag_carrier_before_purchase = 1 THEN NULL
                 WHEN o.order_delivered_carrier_date > oi.shipping_limit_date THEN 1 ELSE 0 END AS BIT) AS missed_handover,
       -- Seller dan pelanggan di negara bagian yang sama?
       CAST(CASE WHEN se.seller_state = c.customer_state THEN 1 ELSE 0 END AS BIT) AS is_same_state,
       o.seller_handling_days,
       o.is_late,
       o.is_delivered,
       o.in_analysis_window,
       r.review_score
FROM dbo.order_items AS oi
JOIN dbo.orders    AS o  ON o.order_id    = oi.order_id
JOIN dbo.sellers   AS se ON se.seller_id  = oi.seller_id
JOIN dbo.customers AS c  ON c.customer_id = o.customer_id
LEFT JOIN dbo.order_reviews AS r ON r.order_id = oi.order_id;
GO


/* ---------------------------------------------------------------------
   CHECK: grain dan total uang
   --------------------------------------------------------------------- */
-- 1) fact_orders: satu baris per order (99441 = 99441)
SELECT COUNT(*) AS fact_rows, COUNT(DISTINCT order_id) AS distinct_orders FROM dbo.vw_fact_orders;

-- 2) fact_order_items: jumlah baris dan total harga sama dengan tabel asal
SELECT (SELECT COUNT(*) FROM dbo.vw_fact_order_items) AS fact_rows,
       (SELECT COUNT(*) FROM dbo.order_items)         AS source_rows,
       (SELECT SUM(price) FROM dbo.vw_fact_order_items) AS fact_price,
       (SELECT SUM(price) FROM dbo.order_items)         AS source_price;

-- 3) Bukti fan-out: JOIN langsung tanpa agregasi membuat total harga membengkak
SELECT SUM(oi.price) AS inflated_price_if_joined_naively
FROM dbo.orders AS o
JOIN dbo.order_items    AS oi ON oi.order_id = o.order_id
JOIN dbo.order_payments AS op ON op.order_id = o.order_id;
GO
