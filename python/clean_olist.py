"""
Olist Delivery Performance - data cleaning (pandas)

Input : 9 CSV dari Kaggle "Brazilian E-Commerce Public Dataset by Olist" (folder archive/)
Output: CSV bersih di folder clean/, siap dimuat ke SQL Server

Prinsip:
- Data asli tidak diubah diam-diam. Nilai yang janggal ditandai dengan kolom flag_*,
  lalu baru dikeluarkan dari perhitungan durasi.
- Setiap langkah mencetak berapa baris yang terdampak, supaya bisa dicek ulang.

Cara menjalankan (dari folder portofolio_2):
    python python/clean_olist.py
"""
from pathlib import Path
import unicodedata

import numpy as np
import pandas as pd

BASE = Path(__file__).resolve().parent.parent
RAW = BASE / "archive"
OUT = BASE / "clean"
OUT.mkdir(exist_ok=True)

ANALYSIS_START = pd.Timestamp("2017-01-01")
ANALYSIS_END = pd.Timestamp("2018-08-31 23:59:59")


def log(step, msg):
    print(f"[{step}] {msg}")


def read(name, **kw):
    # utf-8-sig: file terjemahan kategori diawali BOM
    return pd.read_csv(RAW / name, encoding="utf-8-sig", **kw)


# ---------------------------------------------------------------------------
# 1. Load
# ---------------------------------------------------------------------------
ID = str
orders = read("olist_orders_dataset.csv", dtype={"order_id": ID, "customer_id": ID})
items = read("olist_order_items_dataset.csv", dtype={"order_id": ID, "product_id": ID, "seller_id": ID})
payments = read("olist_order_payments_dataset.csv", dtype={"order_id": ID})
reviews = read("olist_order_reviews_dataset.csv", dtype={"review_id": ID, "order_id": ID})
customers = read("olist_customers_dataset.csv",
                 dtype={"customer_id": ID, "customer_unique_id": ID, "customer_zip_code_prefix": ID})
sellers = read("olist_sellers_dataset.csv", dtype={"seller_id": ID, "seller_zip_code_prefix": ID})
products = read("olist_products_dataset.csv", dtype={"product_id": ID})
geo = read("olist_geolocation_dataset.csv", dtype={"geolocation_zip_code_prefix": ID})
cat = read("product_category_name_translation.csv")

for name, df in [("orders", orders), ("items", items), ("payments", payments), ("reviews", reviews),
                 ("customers", customers), ("sellers", sellers), ("products", products), ("geo", geo)]:
    log("load", f"{name:9} {len(df):>9,} baris")

# Kode pos disimpan sebagai teks 5 digit (contoh: 01310), supaya angka nol di depan tidak hilang.
for df, col in [(customers, "customer_zip_code_prefix"), (sellers, "seller_zip_code_prefix"),
                (geo, "geolocation_zip_code_prefix")]:
    df[col] = df[col].str.zfill(5)


def normalize_city(s):
    """'São Paulo' -> 'sao paulo': huruf kecil, tanpa aksen, tanpa spasi berlebih."""
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode("ascii")
    return " ".join(s.lower().replace("'", " ").split())


# ---------------------------------------------------------------------------
# 2. Geolocation: 1 juta baris -> 1 titik per kode pos
# ---------------------------------------------------------------------------
n0 = len(geo)
geo = geo.drop_duplicates()
log("geo", f"hapus duplikat persis: {n0 - len(geo):,} baris")

# Batas kasar wilayah Brasil. Titik di luar kotak ini pasti salah input.
in_brazil = geo["geolocation_lat"].between(-34, 6) & geo["geolocation_lng"].between(-74, -34)
log("geo", f"titik di luar Brasil dibuang: {(~in_brazil).sum():,}")
geo = geo[in_brazil].copy()

geo["city"] = geo["geolocation_city"].map(normalize_city)
geo_zip = (
    geo.groupby("geolocation_zip_code_prefix")
    .agg(lat=("geolocation_lat", "median"),        # median: tahan terhadap titik pencilan
         lng=("geolocation_lng", "median"),
         city=("city", lambda s: s.mode().iat[0]),  # nama kota yang paling sering muncul
         state=("geolocation_state", lambda s: s.mode().iat[0]),
         n_points=("geolocation_lat", "size"))
    .reset_index()
    .rename(columns={"geolocation_zip_code_prefix": "zip_code_prefix"})
)
log("geo", f"hasil: {len(geo_zip):,} kode pos unik")

# ---------------------------------------------------------------------------
# 3. Customers & sellers: rapikan kota, tempelkan koordinat
# ---------------------------------------------------------------------------
customers["customer_city"] = customers["customer_city"].map(normalize_city)
customers = customers.merge(
    geo_zip[["zip_code_prefix", "lat", "lng"]],
    left_on="customer_zip_code_prefix", right_on="zip_code_prefix", how="left"
).drop(columns="zip_code_prefix").rename(columns={"lat": "customer_lat", "lng": "customer_lng"})
log("customers", f"kode pos tanpa koordinat: {customers['customer_lat'].isna().sum():,}")

sellers["seller_city"] = sellers["seller_city"].map(normalize_city)
sellers = sellers.merge(
    geo_zip[["zip_code_prefix", "lat", "lng"]],
    left_on="seller_zip_code_prefix", right_on="zip_code_prefix", how="left"
).drop(columns="zip_code_prefix").rename(columns={"lat": "seller_lat", "lng": "seller_lng"})
log("sellers", f"kode pos tanpa koordinat: {sellers['seller_lat'].isna().sum():,}")

# ---------------------------------------------------------------------------
# 4. Products: nama kolom, kategori, berat
# ---------------------------------------------------------------------------
# Nama kolom asli salah ketik ("lenght"), dirapikan.
products = products.rename(columns={
    "product_name_lenght": "product_name_length",
    "product_description_lenght": "product_description_length",
})

# Dua kategori tidak ada di tabel terjemahan: diterjemahkan manual.
extra = pd.DataFrame({
    "product_category_name": ["pc_gamer", "portateis_cozinha_e_preparadores_de_alimentos"],
    "product_category_name_english": ["pc_gamer", "portable_kitchen_and_food_preparers"],
})
cat = pd.concat([cat, extra], ignore_index=True)
products = products.merge(cat, on="product_category_name", how="left")
missing_cat = products["product_category_name"].isna()
log("products", f"tanpa kategori -> 'unknown': {missing_cat.sum():,}")
products.loc[missing_cat, ["product_category_name", "product_category_name_english"]] = "unknown"

# Berat 0 gram tidak mungkin untuk barang yang dikirim: dijadikan kosong.
zero_w = products["product_weight_g"].eq(0)
log("products", f"berat 0 g -> kosong: {zero_w.sum():,}")
products.loc[zero_w, "product_weight_g"] = np.nan

# ---------------------------------------------------------------------------
# 5. Orders: tanggal, durasi tiap tahap, keterlambatan
# ---------------------------------------------------------------------------
date_cols = ["order_purchase_timestamp", "order_approved_at", "order_delivered_carrier_date",
             "order_delivered_customer_date", "order_estimated_delivery_date"]
for c in date_cols:
    orders[c] = pd.to_datetime(orders[c], errors="coerce")

o = orders  # alias pendek
purchase, approved = o["order_purchase_timestamp"], o["order_approved_at"]
carrier, delivered = o["order_delivered_carrier_date"], o["order_delivered_customer_date"]
estimated = o["order_estimated_delivery_date"]

# Flag anomali. Datanya tidak diubah, hanya ditandai.
o["flag_carrier_before_purchase"] = carrier < purchase
o["flag_delivered_before_carrier"] = delivered < carrier
o["flag_delivered_no_date"] = o["order_status"].eq("delivered") & delivered.isna()
o["flag_date_but_not_delivered"] = o["order_status"].ne("delivered") & delivered.notna()
o["flag_no_items"] = ~o["order_id"].isin(items["order_id"])
for f in [c for c in o.columns if c.startswith("flag_")]:
    log("orders", f"{f}: {o[f].sum():,}")

# Durasi tiap tahap (hari, desimal).
day = pd.Timedelta(days=1)
o["approval_hours"] = (approved - purchase) / pd.Timedelta(hours=1)
o["seller_handling_days"] = (carrier - purchase) / day       # beli -> diserahkan ke kurir
o["carrier_transit_days"] = (delivered - carrier) / day      # kurir -> diterima pelanggan
o["total_delivery_days"] = (delivered - purchase) / day      # beli -> diterima
o["estimated_days"] = (estimated - purchase) / day           # janji waktu kirim saat checkout

# Durasi negatif berasal dari timestamp yang salah urut: dikosongkan supaya tidak merusak rata-rata.
for c in ["seller_handling_days", "carrier_transit_days"]:
    neg = o[c] < 0
    o.loc[neg, c] = np.nan

# Keterlambatan dibandingkan per tanggal (estimasi Olist tidak punya jam).
o["delay_days"] = (delivered.dt.normalize() - estimated.dt.normalize()) / day
o["is_late"] = (o["delay_days"] > 0).astype("Int64").where(delivered.notna())  # 1/0, kosong jika belum diterima
dur_cols = ["approval_hours", "seller_handling_days", "carrier_transit_days", "total_delivery_days", "estimated_days"]
o[dur_cols] = o[dur_cols].round(2)
o["is_delivered"] = o["order_status"].eq("delivered") & delivered.notna()

o["purchase_month"] = purchase.dt.to_period("M").astype(str)
o["in_analysis_window"] = purchase.between(ANALYSIS_START, ANALYSIS_END)
log("orders", f"di luar periode analisis Jan 2017 - Agu 2018: {(~o['in_analysis_window']).sum():,}")

# ---------------------------------------------------------------------------
# 6. Reviews: satu ulasan per order
# ---------------------------------------------------------------------------
reviews["review_creation_date"] = pd.to_datetime(reviews["review_creation_date"], errors="coerce")
reviews["review_answer_timestamp"] = pd.to_datetime(reviews["review_answer_timestamp"], errors="coerce")
reviews["has_comment"] = reviews["review_comment_message"].fillna("").str.strip().ne("")

n0 = len(reviews)
# Jika satu order punya beberapa ulasan, yang dipakai adalah ulasan terakhir (versi final pelanggan).
reviews = (reviews.sort_values(["order_id", "review_answer_timestamp"])
                  .drop_duplicates("order_id", keep="last"))
log("reviews", f"ulasan ganda per order dibuang: {n0 - len(reviews):,}")

# ---------------------------------------------------------------------------
# 7. Order items: ongkir, jarak seller -> pelanggan
# ---------------------------------------------------------------------------
items["shipping_limit_date"] = pd.to_datetime(items["shipping_limit_date"], errors="coerce")
items["flag_free_freight"] = items["freight_value"].eq(0)
log("items", f"ongkir 0 (ditandai, bukan dihapus): {items['flag_free_freight'].sum():,}")


def haversine_km(lat1, lng1, lat2, lng2):
    """Jarak garis lurus di permukaan bumi (km)."""
    lat1, lng1, lat2, lng2 = map(np.radians, [lat1, lng1, lat2, lng2])
    a = np.sin((lat2 - lat1) / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin((lng2 - lng1) / 2) ** 2
    return 6371 * 2 * np.arcsin(np.sqrt(a))


tmp = (items[["order_id", "seller_id"]]
       .merge(orders[["order_id", "customer_id"]], on="order_id", how="left")
       .merge(customers[["customer_id", "customer_lat", "customer_lng"]], on="customer_id", how="left")
       .merge(sellers[["seller_id", "seller_lat", "seller_lng"]], on="seller_id", how="left"))
items["distance_km"] = haversine_km(tmp["seller_lat"], tmp["seller_lng"],
                                    tmp["customer_lat"], tmp["customer_lng"]).round(1)
log("items", f"jarak tidak bisa dihitung (koordinat kosong): {items['distance_km'].isna().sum():,}")

# ---------------------------------------------------------------------------
# 8. Payments
# ---------------------------------------------------------------------------
payments["flag_zero_payment"] = payments["payment_value"].eq(0)
log("payments", f"nilai 0: {payments['flag_zero_payment'].sum():,} | "
                f"tipe not_defined: {payments['payment_type'].eq('not_defined').sum():,}")

# ---------------------------------------------------------------------------
# 9. Validasi: script berhenti jika ada aturan yang dilanggar
# ---------------------------------------------------------------------------
assert orders["order_id"].is_unique
assert customers["customer_id"].is_unique
assert sellers["seller_id"].is_unique
assert products["product_id"].is_unique
assert reviews["order_id"].is_unique, "masih ada order dengan >1 ulasan"
assert geo_zip["zip_code_prefix"].is_unique
assert not items.duplicated(["order_id", "order_item_id"]).any()
assert items["order_id"].isin(orders["order_id"]).all(), "ada item tanpa order"
assert items["product_id"].isin(products["product_id"]).all()
assert items["seller_id"].isin(sellers["seller_id"]).all()
assert orders["customer_id"].isin(customers["customer_id"]).all()
assert (orders["seller_handling_days"].dropna() >= 0).all()
assert (orders["carrier_transit_days"].dropna() >= 0).all()
assert products["product_category_name_english"].notna().all()
log("check", "semua validasi lolos")

# ---------------------------------------------------------------------------
# 10. Simpan
# ---------------------------------------------------------------------------
outputs = {
    "orders_clean.csv": orders,
    "order_items_clean.csv": items,
    "order_payments_clean.csv": payments,
    "order_reviews_clean.csv": reviews,
    "customers_clean.csv": customers,
    "sellers_clean.csv": sellers,
    "products_clean.csv": products,
    "geolocation_zip_clean.csv": geo_zip,
}
for fname, df in outputs.items():
    df.to_csv(OUT / fname, index=False, date_format="%Y-%m-%d %H:%M:%S")
    log("save", f"{fname:28} {len(df):>8,} baris, {df.shape[1]} kolom")

d = orders[orders["is_delivered"] & orders["in_analysis_window"]]
log("summary", f"order terkirim (Jan 2017 - Agu 2018): {len(d):,} | "
               f"terlambat: {d['is_late'].mean():.1%} | "
               f"rata-rata beli->diterima: {d['total_delivery_days'].mean():.1f} hari")
