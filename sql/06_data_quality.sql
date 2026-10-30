-- =====================================================================
-- 06_data_quality.sql  |  Automated checks - every row is a problem to look at
-- =====================================================================
SET search_path = fw, public;

CREATE VIEW v_data_quality AS
-- 1. Companies with no annual data at all
SELECT c.ticker, NULL::INT AS fiscal_year, 'no_data' AS check_name,
       'company has no usable 10-K rows' AS detail
FROM dim_company c
WHERE NOT EXISTS (SELECT 1 FROM mv_financials f WHERE f.cik = c.cik)
UNION ALL
-- 2. Gaps in the fiscal-year series
SELECT ticker, fiscal_year, 'year_gap',
       'previous year in data is ' || prev_fiscal_year
FROM v_ratios
WHERE prev_fiscal_year IS NOT NULL AND fiscal_year - prev_fiscal_year > 1
UNION ALL
-- 3. Accounting identity: assets = liabilities + equity (within 5%;
--    equity excludes non-controlling interests so small gaps are normal)
SELECT ticker, fiscal_year, 'balance_identity',
       'assets=' || total_assets || ' vs L+E=' || (total_liabilities + equity)
FROM mv_financials
WHERE ABS(total_assets - (total_liabilities + equity)) > 0.05 * total_assets
UNION ALL
-- 4. Implausible margins
SELECT ticker, fiscal_year, 'margin_outlier',
       'gross margin=' || ROUND(gross_profit / NULLIF(revenue, 0), 3)
FROM mv_financials
WHERE gross_profit / NULLIF(revenue, 0) NOT BETWEEN -1 AND 1
UNION ALL
-- 5. Gross profit larger than revenue / negative revenue
SELECT ticker, fiscal_year, 'negative_or_inconsistent',
       'revenue=' || revenue || ', gross_profit=' || gross_profit
FROM mv_financials
WHERE revenue < 0 OR gross_profit > revenue
UNION ALL
-- 6. Fewer than 3 years of history (growth metrics will be NULL)
SELECT ticker, NULL, 'short_history', COUNT(*) || ' years loaded'
FROM mv_financials
GROUP BY ticker
HAVING COUNT(*) < 4
UNION ALL
-- 7. Latest year: fewer than 9 Piotroski signals computable (info)
SELECT p.ticker, p.fiscal_year, 'incomplete_fscore', p.f_signals || ' of 9 signals available'
FROM v_piotroski p
WHERE p.f_signals < 9
  AND p.fiscal_year = (SELECT MAX(fiscal_year) FROM v_piotroski x WHERE x.ticker = p.ticker)
UNION ALL
-- 8. Latest year without an Altman score
SELECT f.ticker, f.fiscal_year, 'no_altman', 'a required input is missing'
FROM mv_financials f
WHERE f.fiscal_year = (SELECT MAX(fiscal_year) FROM mv_financials x WHERE x.cik = f.cik)
  AND NOT EXISTS (SELECT 1 FROM v_altman a WHERE a.ticker = f.ticker AND a.fiscal_year = f.fiscal_year);
