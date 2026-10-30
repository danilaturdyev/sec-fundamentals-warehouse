-- Q5: Sector scoreboard (each company's latest year): median margin / ROE and Altman zones
SET search_path = fw, public;
WITH latest AS (
    SELECT r.*, ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY fiscal_year DESC) AS yr_rank
    FROM v_ratios r
)
SELECT l.sector,
       COUNT(*)                                                                   AS companies,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.operating_margin))::NUMERIC, 3) AS median_op_margin,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.roe))::NUMERIC, 3)    AS median_roe,
       COUNT(*) FILTER (WHERE a.zone = 'safe')                                    AS safe_zone,
       COUNT(*) FILTER (WHERE a.zone <> 'safe')                                   AS not_safe
FROM latest l
LEFT JOIN v_altman a ON a.ticker = l.ticker AND a.fiscal_year = l.fiscal_year
WHERE l.yr_rank = 1
GROUP BY l.sector
ORDER BY median_op_margin DESC;
