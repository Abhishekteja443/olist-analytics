-- Review score by delivery lateness
SELECT delay_bucket, COUNT(*) AS orders, ROUND(AVG(review_score), 2) AS avg_review
FROM analytics.fact_orders
WHERE delay_bucket IS NOT NULL AND review_score IS NOT NULL
GROUP BY 1 ORDER BY 1;

WITH m AS (
  SELECT DATE_TRUNC('month', order_date)::date AS month, SUM(item_revenue) AS revenue
  FROM analytics.fact_orders WHERE is_valid = 1 GROUP BY 1)
SELECT month, revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / LAG(revenue) OVER (ORDER BY month), 1) AS mom_growth_pct
FROM m ORDER BY month;

SELECT p.category, ROUND(SUM(oi.price)) AS revenue
FROM analytics.fact_order_items oi
JOIN analytics.dim_products p USING (product_id)
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;