DROP SCHEMA IF EXISTS analytics CASCADE;
CREATE SCHEMA analytics;

CREATE TABLE analytics.dim_geo AS
SELECT geolocation_zip_code_prefix AS zip_prefix,
       AVG(geolocation_lat) AS lat,
       AVG(geolocation_lng) AS lng
FROM raw.geolocation
GROUP BY 1;

CREATE VIEW analytics.dim_customers AS
SELECT DISTINCT ON (c.customer_unique_id)
       c.customer_unique_id,
       INITCAP(c.customer_city) AS city,
       c.customer_state         AS state,
       'Brazil'                 AS country,
       g.lat, g.lng
FROM raw.customers c
LEFT JOIN analytics.dim_geo g ON g.zip_prefix = c.customer_zip_code_prefix
ORDER BY c.customer_unique_id, c.customer_id;

CREATE VIEW analytics.dim_products AS
SELECT p.product_id,
       COALESCE(t.product_category_name_english,
                p.product_category_name, 'unknown') AS category,
       p.product_weight_g,
       p.product_photos_qty
FROM raw.products p
LEFT JOIN raw.category_translation t
       ON t.product_category_name = p.product_category_name;

CREATE VIEW analytics.dim_sellers AS
SELECT s.seller_id,
       INITCAP(s.seller_city) AS seller_city,
       s.seller_state,
       'Brazil' AS country,
       g.lat, g.lng
FROM raw.sellers s
LEFT JOIN analytics.dim_geo g ON g.zip_prefix = s.seller_zip_code_prefix;

CREATE VIEW analytics.fact_orders AS
WITH items AS (
  SELECT order_id, SUM(price) AS item_revenue,
         SUM(freight_value) AS freight_value, COUNT(*) AS items
  FROM raw.order_items GROUP BY order_id
), reviews AS (
  SELECT order_id, AVG(review_score)::numeric(3,2) AS review_score
  FROM raw.order_reviews GROUP BY order_id
), pay AS (
  SELECT order_id,
         SUM(payment_value) AS payment_value,
         MAX(payment_installments) AS max_installments,
         (ARRAY_AGG(payment_type ORDER BY payment_value DESC))[1] AS main_payment_type
  FROM raw.order_payments GROUP BY order_id
), base AS (
  SELECT
    o.order_id,
    c.customer_unique_id,
    c.customer_state AS customer_state,
    o.order_status,
    o.order_purchase_timestamp                    AS purchase_ts,
    o.order_purchase_timestamp::date              AS order_date,
    o.order_delivered_customer_date::date         AS delivered_date,
    o.order_estimated_delivery_date::date         AS estimated_date,
    COALESCE(i.item_revenue, 0)                   AS item_revenue,
    COALESCE(i.freight_value, 0)                  AS freight_value,
    COALESCE(i.items, 0)                          AS items,
    p.payment_value, p.max_installments, p.main_payment_type,
    r.review_score,
    CASE WHEN o.order_status NOT IN ('canceled','unavailable')
          AND i.order_id IS NOT NULL THEN 1 ELSE 0 END AS is_valid,
    ROUND(EXTRACT(EPOCH FROM (o.order_delivered_customer_date
          - o.order_purchase_timestamp)) / 86400.0, 1) AS delivery_days,
    (o.order_delivered_customer_date::date
          - o.order_estimated_delivery_date::date)     AS delay_days
  FROM raw.orders o
  JOIN raw.customers c ON c.customer_id = o.customer_id
  LEFT JOIN items i   ON i.order_id = o.order_id
  LEFT JOIN reviews r ON r.order_id = o.order_id
  LEFT JOIN pay p     ON p.order_id = o.order_id
  WHERE o.order_purchase_timestamp >= '2017-01-01'
    AND o.order_purchase_timestamp <  '2018-09-01'
)
SELECT base.*,
  CASE WHEN delay_days IS NULL THEN NULL
       WHEN delay_days > 0 THEN 1 ELSE 0 END AS is_late,
  CASE WHEN delay_days IS NULL THEN NULL
       WHEN delay_days <= 0 THEN '1. On time'
       WHEN delay_days <= 3 THEN '2. 1-3 days late'
       WHEN delay_days <= 7 THEN '3. 4-7 days late'
       ELSE '4. 8+ days late' END AS delay_bucket
FROM base;

CREATE VIEW analytics.fact_order_items AS
SELECT oi.order_id, oi.order_item_id, oi.product_id, oi.seller_id,
       oi.price, oi.freight_value, fo.order_date
FROM raw.order_items oi
JOIN analytics.fact_orders fo ON fo.order_id = oi.order_id
WHERE fo.is_valid = 1;

CREATE VIEW analytics.customer_rfm AS
WITH base AS (
  SELECT customer_unique_id,
         MAX(order_date)           AS last_order,
         COUNT(DISTINCT order_id)  AS frequency,
         SUM(item_revenue)         AS monetary
  FROM analytics.fact_orders
  WHERE order_status = 'delivered' AND is_valid = 1
  GROUP BY 1
), snap AS (SELECT MAX(order_date) + 1 AS d FROM analytics.fact_orders),
scored AS (
  SELECT b.*, (s.d - b.last_order) AS recency_days,
         NTILE(5) OVER (ORDER BY (s.d - b.last_order) DESC) AS r_score,
         CASE WHEN b.frequency = 1 THEN 1 WHEN b.frequency = 2 THEN 3 ELSE 5 END AS f_score,
         NTILE(5) OVER (ORDER BY b.monetary) AS m_score
  FROM base b CROSS JOIN snap s
)
SELECT *,
  CASE WHEN r_score >= 4 AND f_score >= 3 THEN 'Champions'
       WHEN f_score >= 3                  THEN 'Repeat Buyers'
       WHEN r_score >= 4 AND m_score >= 4 THEN 'New Big Spenders'
       WHEN r_score >= 4                  THEN 'Recent Customers'
       WHEN r_score <= 2 AND m_score >= 4 THEN 'At-Risk High Value'
       WHEN r_score <= 2                  THEN 'Lost / Dormant'
       ELSE 'Needs Attention' END AS segment
FROM scored;

CREATE VIEW analytics.cohort_retention AS
WITH o AS (
  SELECT customer_unique_id, DATE_TRUNC('month', order_date)::date AS m
  FROM analytics.fact_orders
  WHERE order_status = 'delivered' AND is_valid = 1
  GROUP BY 1, 2
), fc AS (
  SELECT customer_unique_id, MIN(m) AS cohort FROM o GROUP BY 1
)
SELECT fc.cohort AS cohort_month,
       ((EXTRACT(YEAR FROM o.m) - EXTRACT(YEAR FROM fc.cohort)) * 12
        + EXTRACT(MONTH FROM o.m) - EXTRACT(MONTH FROM fc.cohort))::int AS months_since,
       COUNT(DISTINCT o.customer_unique_id) AS active_customers
FROM o JOIN fc USING (customer_unique_id)
GROUP BY 1, 2;