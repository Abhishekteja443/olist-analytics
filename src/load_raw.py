import os
from pathlib import Path
import pandas as pd
from sqlalchemy import URL, create_engine, text

from dotenv import load_dotenv

load_dotenv()

DB_URL = URL.create(
    "postgresql+psycopg2",
    username=os.getenv("POSTGRES_USER"),
    password=os.getenv("POSTGRES_PASSWORD"),
    host=os.getenv("POSTGRES_HOST"),
    port=os.getenv("POSTGRES_PORT"),
    database=os.getenv("POSTGRES_DB"),
)
RAW = Path("data/raw")

FILES = {
    "customers": "olist_customers_dataset.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "orders": "olist_orders_dataset.csv",
    "products": "olist_products_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}

DATE_COLS = {
    "orders": [
        "order_purchase_timestamp", "order_approved_at",
        "order_delivered_carrier_date", "order_delivered_customer_date",
        "order_estimated_delivery_date",
    ],
    "order_items": ["shipping_limit_date"],
    "order_reviews": ["review_creation_date", "review_answer_timestamp"],
}

engine = create_engine(DB_URL)
with engine.begin() as con:
    con.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))

for table, filename in FILES.items():
    df = pd.read_csv(RAW / filename, parse_dates=DATE_COLS.get(table, []))
    df.to_sql(table, engine, schema="raw", if_exists="replace",
              index=False, chunksize=10_000, method="multi")
    print(f"loaded raw.{table}: {len(df):,} rows")