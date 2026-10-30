-- Q3: Fastest 3-year revenue growers per sector (top 2 each) with cash conversion,
-- using each company's own latest fiscal year
SET search_path = fw, public;
WITH latest AS (
    SELECT r.*, ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY fiscal_year DESC) AS yr_rank
    FROM v_ratios r
)
SELECT * FROM (
    SELECT ticker, sector, fiscal_year, revenue_cagr_3y, cash_conversion,
           ROW_NUMBER() OVER (PARTITION BY sector ORDER BY revenue_cagr_3y DESC NULLS LAST) AS rn
    FROM latest WHERE yr_rank = 1
) x WHERE rn <= 2 ORDER BY sector, rn;
