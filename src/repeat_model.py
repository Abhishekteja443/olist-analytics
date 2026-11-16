import os
import pandas as pd
from sqlalchemy import URL, create_engine
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score, average_precision_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
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
engine = create_engine(DB_URL)

df = pd.read_sql("""
    WITH ranked AS (
      SELECT fo.*,
             ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS rn,
             COUNT(*)     OVER (PARTITION BY customer_unique_id) AS n_orders
      FROM analytics.fact_orders fo
      WHERE order_status = 'delivered' AND is_valid = 1)
    SELECT customer_unique_id, item_revenue, freight_value, items,
           max_installments, review_score, delivery_days, is_late,
           main_payment_type, customer_state,
           (n_orders > 1)::int AS repeat
    FROM ranked
    WHERE rn = 1 AND purchase_ts < '2018-03-01'""", engine)

print(f"Customers: {len(df):,} | repeat rate: {df['repeat'].mean():.2%}")

ids = df.pop("customer_unique_id")
y = df.pop("repeat")
X = pd.get_dummies(df, columns=["main_payment_type", "customer_state"], dtype=int)
X["freight_ratio"] = X["freight_value"] / (X["item_revenue"] + 1)

Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.25,
                                      stratify=y, random_state=42)

baseline = make_pipeline(StandardScaler(),
                         LogisticRegression(max_iter=1000, class_weight="balanced"))
baseline.fit(Xtr.fillna(Xtr.median()), ytr)
lr_p = baseline.predict_proba(Xte.fillna(Xtr.median()))[:, 1]

gb = HistGradientBoostingClassifier(max_depth=4, learning_rate=0.05,
                                    class_weight="balanced", random_state=42)
gb.fit(Xtr, ytr)
gb_p = gb.predict_proba(Xte)[:, 1]

for name, p in [("LogReg", lr_p), ("GradBoost", gb_p)]:
    print(f"{name}: ROC-AUC={roc_auc_score(yte, p):.3f}  "
          f"PR-AUC={average_precision_score(yte, p):.3f}")

scores = pd.DataFrame({"customer_unique_id": ids,
                       "repeat_probability": gb.predict_proba(X)[:, 1],
                       "actual_repeat": y})
scores.to_sql("repeat_propensity", engine, schema="analytics",
              if_exists="replace", index=False)