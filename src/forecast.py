import os
import numpy as np
import pandas as pd
from sqlalchemy import URL, URL, create_engine
from statsmodels.tsa.holtwinters import ExponentialSmoothing


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

monthly = pd.read_sql("""
    SELECT DATE_TRUNC('month', order_date)::date AS month,
           SUM(item_revenue) AS revenue
    FROM analytics.fact_orders WHERE is_valid = 1
    GROUP BY 1 ORDER BY 1""", engine, parse_dates=["month"])
y = monthly.set_index("month")["revenue"].asfreq("MS")

train, test = y.iloc[:-3], y.iloc[-3:]
bt = ExponentialSmoothing(train, trend="add").fit()
mape = (np.abs(test - bt.forecast(3)) / test).mean() * 100
print(f"Backtest MAPE on last 3 months: {mape:.1f}%")

fit = ExponentialSmoothing(y, trend="add").fit()
horizon = 6
fc = fit.forecast(horizon)
sigma = np.std(fit.resid, ddof=1)

actual = pd.DataFrame({"month": y.index, "revenue": y.values,
                       "forecast": np.nan, "lower": np.nan, "upper": np.nan,
                       "type": "actual"})
future = pd.DataFrame({"month": fc.index, "revenue": np.nan,
                       "forecast": fc.values,
                       "lower": fc.values - 1.96 * sigma,
                       "upper": fc.values + 1.96 * sigma,
                       "type": "forecast"})
out = pd.concat([actual, future], ignore_index=True)
out.to_sql("revenue_forecast", engine, schema="analytics",
           if_exists="replace", index=False)
print(out.tail(8))