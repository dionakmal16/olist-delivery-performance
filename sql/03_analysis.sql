/* =====================================================================
   OLIST DELIVERY PERFORMANCE  |  03 - ANALISIS (T-SQL)
   Jalankan setelah 01_setup.sql dan 02_star_schema.sql.

   Filter standar di hampir semua query:
     is_delivered = 1       -> hanya order yang benar-benar sampai
     in_analysis_window = 1 -> Jan 2017 - Agu 2018 (data 2016 & Sep-Okt 2018 tidak lengkap)
     has_date_anomaly = 0   -> buang order dengan timestamp janggal saat menghitung durasi

   Format setiap query: Pertanyaan -> Teknik -> Hasil -> Insight
   Hasil dijalankan di SQL Server 2025 Express.
   ===================================================================== */
USE OlistDB;
GO


/* =====================================================================
   A. KINERJA PENGIRIMAN SECARA UMUM
   ===================================================================== */

/* ---- A1. Tren bulanan: keterlambatan dan lama pengiriman ------------
   Pertanyaan : Apakah ketepatan waktu membaik dari waktu ke waktu?
   Teknik     : GROUP BY bulan; AVG dari kolom 0/1 = persentase.
   Hasil      : Normal 3-5% terlambat, tetapi melonjak di
                Nov 2017 (12,4%), Feb 2018 (14,1%), dan Mar 2018 (19,0%).
                Lama kirim turun dari ±12 hari (2017) ke 7,7 hari (Agu 2018),
                dan estimasi juga dipangkas dari ±23 hari ke 15,2 hari.
   Insight    : Lonjakan Nov 2017 bertepatan dengan Black Friday, ketika
                volume order naik 63% dari Oktober. Kapasitas pengiriman
                tidak mengimbangi lonjakan permintaan. Lonjakan Feb-Mar 2018
                perlu ditelusuri, karena volumenya tidak naik tajam.         */
SELECT FORMAT(purchase_date, 'yyyy-MM')                          AS purchase_month,
       COUNT(*)                                                  AS orders,
       CAST(100.0 * AVG(CAST(is_late AS FLOAT)) AS DECIMAL(5,1)) AS late_pct,
       CAST(AVG(total_delivery_days) AS DECIMAL(5,1))            AS avg_delivery_days,
       CAST(AVG(estimated_days) AS DECIMAL(5,1))                 AS avg_estimated_days
FROM dbo.vw_fact_orders
WHERE is_delivered = 1 AND in_analysis_window = 1 AND has_date_anomaly = 0
GROUP BY FORMAT(purchase_date, 'yyyy-MM')
ORDER BY purchase_month;


/* ---- A2. Di tahap mana waktu habis? ----------------------------------
   Pertanyaan : Apakah keterlambatan disebabkan seller atau kurir?
   Teknik     : AVG per tahap, dibandingkan antara order tepat waktu dan terlambat.
   Hasil      :            seller (beli->kurir) | kurir (kurir->pelanggan) | estimasi
                tepat waktu      3,0 hari       |        8,0 hari          | 23,7 hari
                terlambat        6,0 hari       |       27,9 hari          | 22,6 hari
                (rata-rata semua order: approval 10,3 jam, seller 3,2 hari,
                 kurir 9,3 hari, total 12,6 hari; median total 10,2 hari)
   Insight    : Pada order terlambat, waktu kurir 3,5x lebih lama, sedangkan
                waktu seller hanya 2x lebih lama. Sumber utama keterlambatan
                ada di tahap pengiriman oleh kurir, tetapi seller yang lambat
                ikut menambah risiko (lihat D1).                            */
SELECT is_late,
       COUNT(*)                                        AS orders,
       CAST(AVG(seller_handling_days) AS DECIMAL(5,2)) AS avg_seller_days,
       CAST(AVG(carrier_transit_days) AS DECIMAL(5,2)) AS avg_carrier_days,
       CAST(AVG(estimated_days) AS DECIMAL(5,2))       AS avg_estimated_days
FROM dbo.vw_fact_orders
WHERE is_delivered = 1 AND in_analysis_window = 1 AND has_date_anomaly = 0
GROUP BY is_late;

-- Median: PERCENTILE_CONT adalah window function, jadi pakai OVER () dan DISTINCT
SELECT DISTINCT
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY seller_handling_days) OVER () AS median_seller_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY carrier_transit_days) OVER () AS median_carrier_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_delivery_days)  OVER () AS median_total_days
FROM dbo.vw_fact_orders
WHERE is_delivered = 1 AND in_analysis_window = 1 AND has_date_anomaly = 0;


/* ---- A3. Seberapa akurat estimasi pengiriman? ------------------------
   Pertanyaan : Apakah janji tanggal sampai di halaman checkout realistis?
   Teknik     : CASE untuk membuat kelompok selisih hari; SUM(COUNT(*)) OVER ()
                untuk persentase dari total.
   Hasil      : 36,1% tiba >=15 hari lebih cepat | 37,8% tiba 8-14 hari lebih cepat
                18,0% tiba 1-7 hari lebih cepat   |  1,3% tepat di hari estimasi
                 6,8% terlambat (1,9% 1-3 hari, 1,9% 4-7 hari, 3,0% >7 hari)
   Insight    : Estimasi sangat konservatif: rata-rata 23,7 hari, padahal
                kenyataannya 12,6 hari. Ini aman untuk menekan keterlambatan,
                tetapi waktu tunggu yang ditampilkan saat checkout terlalu
                panjang dan berpotensi membuat calon pembeli batal.          */
WITH bucketed AS (
    SELECT CASE WHEN delay_days <= -15 THEN '1. >=15 days early'
                WHEN delay_days <= -8  THEN '2. 8-14 days early'
                WHEN delay_days <= -1  THEN '3. 1-7 days early'
                WHEN delay_days =  0   THEN '4. On estimated day'
                WHEN delay_days <= 3   THEN '5. 1-3 days late'
                WHEN delay_days <= 7   THEN '6. 4-7 days late'
                ELSE                        '7. >7 days late' END AS delay_bucket,
           review_score
    FROM dbo.vw_fact_orders
    WHERE is_delivered = 1 AND in_analysis_window = 1
)
SELECT delay_bucket,
       COUNT(*)                                                      AS orders,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct_of_orders,
       CAST(AVG(CAST(review_score AS FLOAT)) AS DECIMAL(3,2))        AS avg_review,
       CAST(100.0 * AVG(CASE WHEN review_score = 1 THEN 1.0 ELSE 0 END) AS DECIMAL(5,1)) AS one_star_pct
FROM bucketed
GROUP BY delay_bucket
ORDER BY delay_bucket;


/* =====================================================================
   B. GEOGRAFI
   ===================================================================== */

/* ---- B1. Keterlambatan per wilayah dan negara bagian -----------------
   Pertanyaan : Di mana pelanggan paling sering menerima barang terlambat?
   Teknik     : JOIN fakta -> dimensi customer -> tabel referensi dim_state.
   Hasil      : Region   | order  | terlambat | lama kirim | estimasi
                Northeast|  9.002 |   12,8%   |  20,0 hari | 30,5 hari
                North    |  1.789 |    8,6%   |  22,6 hari | 37,5 hari
                Southeast| 65.905 |    6,1%   |  10,7 hari | 21,5 hari
                Terburuk : Alagoas 21,5%, Maranhão 17,6%, Sergipe 15,4%
                Anomali  : Rio de Janeiro 12,2%, padahal satu wilayah dengan
                           São Paulo (4,5%).
   Insight    : Wilayah Utara pengirimannya paling lama (22,6 hari), tetapi
                tingkat terlambatnya lebih rendah dari Timur Laut, karena
                estimasinya dibuat sangat panjang (37,5 hari). Timur Laut paling
                sering terlambat karena estimasinya tidak cukup longgar. Rio de Janeiro perlu ditelusuri terpisah,
                karena jaraknya dekat dengan pusat seller di São Paulo.     */
SELECT s.region,
       COUNT(*)                                                    AS orders,
       CAST(100.0 * AVG(CAST(f.is_late AS FLOAT)) AS DECIMAL(5,1)) AS late_pct,
       CAST(AVG(f.total_delivery_days) AS DECIMAL(5,1))            AS avg_delivery_days,
       CAST(AVG(f.estimated_days) AS DECIMAL(5,1))                 AS avg_estimated_days
FROM dbo.vw_fact_orders AS f
JOIN dbo.customers AS c ON c.customer_id = f.customer_id
JOIN dbo.dim_state AS s ON s.state = c.customer_state
WHERE f.is_delivered = 1 AND f.in_analysis_window = 1 AND f.has_date_anomaly = 0
GROUP BY s.region
ORDER BY late_pct DESC;

-- Detail per negara bagian (untuk peta di Power BI)
SELECT s.state, s.state_name, s.region,
       COUNT(*)                                                    AS orders,
       CAST(100.0 * AVG(CAST(f.is_late AS FLOAT)) AS DECIMAL(5,1)) AS late_pct,
       CAST(AVG(f.total_delivery_days) AS DECIMAL(5,1))            AS avg_delivery_days
FROM dbo.vw_fact_orders AS f
JOIN dbo.customers AS c ON c.customer_id = f.customer_id
JOIN dbo.dim_state AS s ON s.state = c.customer_state
WHERE f.is_delivered = 1 AND f.in_analysis_window = 1 AND f.has_date_anomaly = 0
GROUP BY s.state, s.state_name, s.region
ORDER BY late_pct DESC;


/* ---- B2. Pengiriman dalam satu negara bagian vs antar negara bagian --
   Pertanyaan : Seberapa besar pengaruh lokasi seller terhadap pengiriman?
   Teknik     : JOIN seller dan customer, lalu CASE membandingkan dua kolom
                dari tabel berbeda; SELECT DISTINCT agar setiap order hanya
                dihitung sekali.
   Hasil      : satu negara bagian  : 34.675 order, 4,5% terlambat, 7,9 hari
                antar negara bagian : 61.586 order, 8,1% terlambat, 15,1 hari
   Insight    : Pengiriman lintas negara bagian 2x lebih lama dan hampir 2x
                lebih sering terlambat. Mendorong seller di luar São Paulo
                (atau gudang regional) bisa memangkas waktu kirim.          */
WITH order_route AS (
    SELECT DISTINCT f.order_id,
           f.is_late,
           o.total_delivery_days,
           CASE WHEN se.seller_state = c.customer_state THEN 'Same state' ELSE 'Different state' END AS route
    FROM dbo.vw_fact_order_items AS f
    JOIN dbo.orders    AS o  ON o.order_id     = f.order_id
    JOIN dbo.sellers   AS se ON se.seller_id   = f.seller_id
    JOIN dbo.customers AS c  ON c.customer_id  = f.customer_id
    WHERE f.is_delivered = 1 AND f.in_analysis_window = 1
      AND o.flag_carrier_before_purchase = 0 AND o.flag_delivered_before_carrier = 0
)
SELECT route,
       COUNT(*)                                                  AS orders,
       CAST(100.0 * AVG(CAST(is_late AS FLOAT)) AS DECIMAL(5,1)) AS late_pct,
       CAST(AVG(total_delivery_days) AS DECIMAL(5,1))            AS avg_delivery_days
FROM order_route
GROUP BY route;


/* ---- B3. Jarak seller -> pelanggan -----------------------------------
   Pertanyaan : Bagaimana jarak memengaruhi waktu, keterlambatan, dan ongkir?
   Teknik     : Jarak dihitung di Python (haversine), dikelompokkan dengan CASE.
   Hasil      : jarak       | order  | terlambat | lama kirim | ongkir rata-rata
                < 100 km    | 17.718 |   4,5%    |   6,5 hari |  13,31
                100-500 km  | 36.793 |   6,1%    |  11,5 hari |  20,96
                500-1000 km | 25.707 |   7,1%    |  14,3 hari |  24,22
                1000-2000 km|  9.728 |   9,5%    |  17,9 hari |  33,18
                >= 2000 km  |  5.596 |  12,1%    |  21,1 hari |  39,91
   Insight    : Setiap kenaikan kelompok jarak menambah waktu kirim dan risiko
                terlambat secara konsisten. Di atas 2.000 km, risiko terlambat
                2,7x lebih besar daripada di bawah 100 km.                  */
SELECT CASE WHEN max_distance_km < 100  THEN '1. < 100 km'
            WHEN max_distance_km < 500  THEN '2. 100-500 km'
            WHEN max_distance_km < 1000 THEN '3. 500-1000 km'
            WHEN max_distance_km < 2000 THEN '4. 1000-2000 km'
            ELSE                             '5. >= 2000 km' END AS distance_band,
       COUNT(*)                                                  AS orders,
       CAST(100.0 * AVG(CAST(is_late AS FLOAT)) AS DECIMAL(5,1)) AS late_pct,
       CAST(AVG(total_delivery_days) AS DECIMAL(5,1))            AS avg_delivery_days,
       CAST(AVG(freight_value) AS DECIMAL(6,2))                  AS avg_freight
FROM dbo.vw_fact_orders
WHERE is_delivered = 1 AND in_analysis_window = 1 AND has_date_anomaly = 0
  AND max_distance_km IS NOT NULL
GROUP BY CASE WHEN max_distance_km < 100  THEN '1. < 100 km'
              WHEN max_distance_km < 500  THEN '2. 100-500 km'
              WHEN max_distance_km < 1000 THEN '3. 500-1000 km'
              WHEN max_distance_km < 2000 THEN '4. 1000-2000 km'
              ELSE                             '5. >= 2000 km' END
ORDER BY distance_band;


/* =====================================================================
   C. PENGALAMAN PELANGGAN
   ===================================================================== */

/* ---- C1. Apakah keterlambatan menurunkan rating? ---------------------
   Pertanyaan : Seberapa besar dampak keterlambatan pada ulasan?
   Teknik     : AVG rating per kelompok; CASE di dalam AVG untuk persentase.
   Hasil      : tepat waktu : rating 4,29 | ulasan 1-2 bintang  9,2%
                terlambat   : rating 2,27 | ulasan 1-2 bintang 62,4%
                Order terlambat hanya 6,8% dari order terkirim, tetapi
                menyumbang 36,8% dari semua ulasan bintang 1.
                Terlambat >7 hari: rating 1,70, dan 67,8% di antaranya bintang 1.
                (Order yang tidak pernah sampai: rating 1,75.)
   Insight    : Keterlambatan adalah pendorong terbesar ulasan buruk. Rating
                turun hampir 2 poin, dan efeknya langsung terasa sejak
                terlambat 1-3 hari (rating 3,29). Ketepatan waktu adalah tuas
                paling efektif untuk menjaga kepuasan pelanggan.            */
SELECT is_late,
       COUNT(*)                                               AS orders,
       CAST(AVG(CAST(review_score AS FLOAT)) AS DECIMAL(3,2)) AS avg_review,
       CAST(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1.0 ELSE 0 END) AS DECIMAL(5,1)) AS low_review_pct
FROM dbo.vw_fact_orders
WHERE is_delivered = 1 AND in_analysis_window = 1 AND review_score IS NOT NULL
GROUP BY is_late;

-- Porsi ulasan bintang 1 yang berasal dari order terlambat
SELECT COUNT(*) AS one_star_reviews,
       CAST(100.0 * SUM(CASE WHEN is_late = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS from_late_orders_pct
FROM dbo.vw_fact_orders
WHERE is_delivered = 1 AND in_analysis_window = 1 AND review_score = 1;


/* =====================================================================
   D. PERFORMA SELLER
   ===================================================================== */

/* ---- D1. Seller yang terlambat menyerahkan barang ke kurir -----------
   Pertanyaan : Seberapa sering seller melewati batas waktu serah ke kurir
                (shipping_limit_date), dan apa dampaknya?
   Teknik     : MAX(CASE ...) per order: order dianggap "melewati batas"
                jika minimal satu item terlambat diserahkan.
   Hasil      : melewati batas : 8.580 order (8,9%) | 21,1% terlambat | rating 3,70
                tepat batas    : 87.439 order       |  5,4% terlambat | rating 4,20
   Insight    : Jika seller terlambat menyerahkan barang, peluang order
                sampai terlambat naik hampir 4x. Batas serah ke kurir adalah
                indikator dini yang bisa dipantau setiap hari, sebelum
                pelanggan mengeluh.                                           */
WITH order_handover AS (
    SELECT oi.order_id,
           MAX(CASE WHEN o.order_delivered_carrier_date > oi.shipping_limit_date THEN 1 ELSE 0 END) AS missed_limit
    FROM dbo.order_items AS oi
    JOIN dbo.orders AS o ON o.order_id = oi.order_id
    WHERE o.is_delivered = 1 AND o.in_analysis_window = 1
      AND o.flag_carrier_before_purchase = 0 AND o.flag_delivered_before_carrier = 0
    GROUP BY oi.order_id
)
SELECT h.missed_limit,
       COUNT(*)                                                      AS orders,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct_of_orders,
       CAST(100.0 * AVG(CAST(o.is_late AS FLOAT)) AS DECIMAL(5,1))   AS late_pct,
       CAST(AVG(CAST(r.review_score AS FLOAT)) AS DECIMAL(3,2))      AS avg_review
FROM order_handover AS h
JOIN dbo.orders AS o ON o.order_id = h.order_id
LEFT JOIN dbo.order_reviews AS r ON r.order_id = h.order_id
GROUP BY h.missed_limit;


/* ---- D2. Scorecard seller: kecepatan proses vs hasil -----------------
   Pertanyaan : Apakah seller yang lambat memproses order punya hasil lebih buruk?
   Teknik     : CTE scorecard per seller; HAVING untuk sampel minimal 50 order;
                NTILE(4) membagi seller menjadi 4 kelompok sama besar.
   Hasil      : 424 seller dengan >=50 order menghasilkan 68,1% revenue.
                kuartil | proses seller | terlambat | rating
                  1     |   1,68 hari   |   4,2%    |  4,29
                  2     |   2,27 hari   |   5,9%    |  4,13
                  3     |   3,17 hari   |   6,7%    |  4,10
                  4     |   5,68 hari   |   8,9%    |  3,88
   Insight    : Seller paling lambat (kuartil 4) punya tingkat keterlambatan
                2x lipat dibanding yang tercepat, dan rating 0,4 poin lebih
                rendah. Standar waktu proses, misalnya maksimal 3 hari,
                layak diterapkan.                                          */
WITH seller_scorecard AS (
    SELECT f.seller_id,
           COUNT(DISTINCT f.order_id)              AS orders,
           AVG(f.seller_handling_days)             AS avg_handling_days,
           AVG(CAST(f.is_late AS FLOAT))           AS late_rate,
           AVG(CAST(f.review_score AS FLOAT))      AS avg_review
    FROM dbo.vw_fact_order_items AS f
    WHERE f.is_delivered = 1 AND f.in_analysis_window = 1
    GROUP BY f.seller_id
    HAVING COUNT(DISTINCT f.order_id) >= 50       -- sampel kecil tidak bisa dipercaya
),
quartiles AS (
    SELECT *, NTILE(4) OVER (ORDER BY avg_handling_days) AS handling_quartile
    FROM seller_scorecard
)
SELECT handling_quartile,
       COUNT(*)                                        AS sellers,
       CAST(AVG(avg_handling_days) AS DECIMAL(5,2))    AS avg_handling_days,
       CAST(100 * AVG(late_rate) AS DECIMAL(5,1))      AS late_pct,
       CAST(AVG(avg_review) AS DECIMAL(3,2))           AS avg_review
FROM quartiles
GROUP BY handling_quartile
ORDER BY handling_quartile;

-- 10 seller (>=50 order) dengan tingkat keterlambatan tertinggi
WITH seller_scorecard AS (
    SELECT f.seller_id, se.seller_state,
           COUNT(DISTINCT f.order_id)         AS orders,
           AVG(f.seller_handling_days)        AS avg_handling_days,
           AVG(CAST(f.is_late AS FLOAT))      AS late_rate,
           AVG(CAST(f.review_score AS FLOAT)) AS avg_review
    FROM dbo.vw_fact_order_items AS f
    JOIN dbo.sellers AS se ON se.seller_id = f.seller_id
    WHERE f.is_delivered = 1 AND f.in_analysis_window = 1
    GROUP BY f.seller_id, se.seller_state
    HAVING COUNT(DISTINCT f.order_id) >= 50
)
SELECT TOP 10
       RANK() OVER (ORDER BY late_rate DESC) AS late_rank,
       seller_id, seller_state, orders,
       CAST(100 * late_rate AS DECIMAL(5,1))     AS late_pct,
       CAST(avg_handling_days AS DECIMAL(5,1))   AS avg_handling_days,
       CAST(avg_review AS DECIMAL(3,2))          AS avg_review
FROM seller_scorecard
ORDER BY late_rate DESC;


/* =====================================================================
   E. ONGKOS KIRIM
   ===================================================================== */

/* ---- E1. Beban ongkir dibanding harga barang -------------------------
   Pertanyaan : Untuk barang seperti apa ongkir terasa paling memberatkan?
   Teknik     : Rasio total ongkir / total harga per kelompok harga.
   Hasil      : harga < 50     : ongkir = 47,1% dari harga barang
                harga 50-100   : 23,9%
                harga 100-200  : 16,1%
                harga >= 200   :  7,6%
   Insight    : Untuk barang murah, ongkir hampir setengah harga barangnya.
                Promo gratis ongkir dengan minimum belanja (misalnya 100)
                bisa mendorong pembeli menambah barang di keranjang.        */
SELECT CASE WHEN price < 50  THEN '1. < 50'
            WHEN price < 100 THEN '2. 50-100'
            WHEN price < 200 THEN '3. 100-200'
            ELSE                  '4. >= 200' END                     AS price_band,
       COUNT(*)                                                      AS items,
       CAST(100.0 * SUM(freight_value) / SUM(price) AS DECIMAL(5,1)) AS freight_pct_of_price
FROM dbo.vw_fact_order_items
WHERE in_analysis_window = 1
GROUP BY CASE WHEN price < 50  THEN '1. < 50'
              WHEN price < 100 THEN '2. 50-100'
              WHEN price < 200 THEN '3. 100-200'
              ELSE                  '4. >= 200' END
ORDER BY price_band;
GO
