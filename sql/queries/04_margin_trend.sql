-- Q4: Whose operating margin has expanded for 3 consecutive years? (window functions)
SET search_path = fw, public;
WITH t AS (
    SELECT ticker, fiscal_year, operating_margin,
           operating_margin - LAG(operating_margin) OVER (PARTITION BY ticker ORDER BY fiscal_year) AS d1
    FROM v_ratios
)
SELECT ticker, fiscal_year, operating_margin
FROM (
    SELECT t.*,
           MIN(d1) OVER (PARTITION BY ticker ORDER BY fiscal_year ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS min_d,
           COUNT(d1) OVER (PARTITION BY ticker ORDER BY fiscal_year ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS n
    FROM t
) z
WHERE n = 3 AND min_d > 0
ORDER BY ticker, fiscal_year;
