-- =====================================================================
-- 02_clean_financials.sql  |  From raw SEC facts to one row per company-year
-- =====================================================================
SET search_path = fw, public;

-- Step 1: keep annual facts only (10-K), de-duplicate restatements.
--  * flow items must cover ~1 year (350-380 days) so quarterly / YTD
--    numbers inside a 10-K are ignored
--  * if the same period appears in several filings (restatements, later
--    10-Ks showing comparatives) the most recently filed value wins
CREATE VIEW v_annual_fact AS
SELECT cik, tag, period_start, period_end, value, form, filed
FROM (
    SELECT r.*,
           ROW_NUMBER() OVER (
               PARTITION BY cik, tag, period_start, period_end
               ORDER BY filed DESC, accession DESC) AS rn
    FROM raw_xbrl_fact r
    WHERE r.form LIKE '10-K%'
      AND (r.period_start = DATE '1900-01-01'                      -- balance sheet
           OR r.period_end - r.period_start BETWEEN 350 AND 380)   -- full-year flow
) x
WHERE rn = 1;

-- Step 2: map tags to metrics; when a company reports several candidate
-- tags for the same metric and year, take the highest-priority one.
CREATE VIEW v_annual_metric AS
SELECT cik, metric, period_end, value
FROM (
    SELECT f.cik, m.metric, f.period_end, f.value,
           ROW_NUMBER() OVER (
               PARTITION BY f.cik, m.metric, f.period_end
               ORDER BY m.priority) AS rn
    FROM v_annual_fact f
    JOIN dim_metric_map m ON m.tag = f.tag
    -- a flow metric must come from a flow fact and vice versa
    WHERE m.is_flow = (f.period_start <> DATE '1900-01-01')
) x
WHERE rn = 1;

-- Step 3: pivot to one row per company-year (materialised for speed).
-- fiscal_year = calendar year of (period_end - 15 days): handles 52/53-week
-- years ending in the first days of January.
CREATE MATERIALIZED VIEW mv_financials AS
WITH pivoted AS (
    SELECT cik,
           period_end,
           EXTRACT(YEAR FROM (period_end - 15))::INT AS fiscal_year,
           MAX(value) FILTER (WHERE metric = 'revenue')             AS revenue,
           MAX(value) FILTER (WHERE metric = 'cost_of_revenue')     AS cost_of_revenue,
           MAX(value) FILTER (WHERE metric = 'gross_profit')        AS gross_profit_rep,
           MAX(value) FILTER (WHERE metric = 'operating_income')    AS operating_income,
           MAX(value) FILTER (WHERE metric = 'net_income')          AS net_income,
           MAX(value) FILTER (WHERE metric = 'pretax_income')       AS pretax_income,
           MAX(value) FILTER (WHERE metric = 'diluted_shares')      AS diluted_shares,
           MAX(value) FILTER (WHERE metric = 'cfo')                 AS cfo,
           ABS(MAX(value) FILTER (WHERE metric = 'capex'))          AS capex,
           MAX(value) FILTER (WHERE metric = 'total_assets')        AS total_assets,
           MAX(value) FILTER (WHERE metric = 'current_assets')      AS current_assets,
           MAX(value) FILTER (WHERE metric = 'current_liabilities') AS current_liabilities,
           MAX(value) FILTER (WHERE metric = 'total_liabilities')   AS total_liabilities_rep,
           COALESCE(MAX(value) FILTER (WHERE metric = 'long_term_debt'), 0) AS long_term_debt,
           MAX(value) FILTER (WHERE metric = 'equity')              AS equity,
           MAX(value) FILTER (WHERE metric = 'retained_earnings')   AS retained_earnings
    FROM v_annual_metric
    GROUP BY cik, period_end
)
SELECT c.ticker, c.name, c.sector, p.cik, p.fiscal_year, p.period_end,
       p.revenue, p.cost_of_revenue,
       -- derive what some companies do not report directly
       COALESCE(p.gross_profit_rep, p.revenue - p.cost_of_revenue)          AS gross_profit,
       p.operating_income, p.pretax_income,
       -- EBIT proxy: operating income; if the company does not report it
       -- (e.g. Exxon, J&J) fall back to income before tax
       COALESCE(p.operating_income, p.pretax_income)                        AS ebit_proxy,
       p.net_income, p.diluted_shares,
       p.cfo, p.capex, p.cfo - p.capex                                      AS free_cash_flow,
       p.total_assets, p.current_assets, p.current_liabilities,
       COALESCE(p.total_liabilities_rep, p.total_assets - p.equity)         AS total_liabilities,
       p.long_term_debt, p.equity, p.retained_earnings
FROM pivoted p
JOIN dim_company c USING (cik)
-- keep only complete core rows (a 10-K must at least have these)
WHERE p.revenue IS NOT NULL AND p.net_income IS NOT NULL AND p.total_assets IS NOT NULL;

CREATE UNIQUE INDEX ux_mv_financials ON mv_financials (cik, fiscal_year);
