-- =====================================================================
-- 03_ratios.sql  |  Profitability, liquidity, leverage, growth, DuPont
-- =====================================================================
SET search_path = fw, public;

CREATE VIEW v_ratios AS
SELECT
    f.ticker, f.sector, f.cik, f.fiscal_year, f.period_end,
    f.revenue, f.net_income, f.free_cash_flow,
    -- profitability
    ROUND(f.gross_profit    / NULLIF(f.revenue, 0), 4)           AS gross_margin,
    ROUND(f.operating_income/ NULLIF(f.revenue, 0), 4)           AS operating_margin,
    ROUND(f.net_income      / NULLIF(f.revenue, 0), 4)           AS net_margin,
    ROUND(f.free_cash_flow  / NULLIF(f.revenue, 0), 4)           AS fcf_margin,
    ROUND(f.net_income      / NULLIF(f.total_assets, 0), 4)      AS roa,
    ROUND(f.net_income      / NULLIF(f.equity, 0), 4)            AS roe,
    -- liquidity & leverage
    ROUND(f.current_assets  / NULLIF(f.current_liabilities, 0), 2) AS current_ratio,
    ROUND(f.total_liabilities / NULLIF(f.equity, 0), 2)          AS liabilities_to_equity,
    ROUND(f.long_term_debt  / NULLIF(f.total_assets, 0), 4)      AS lt_debt_to_assets,
    -- quality of earnings: cash conversion
    ROUND(f.cfo / NULLIF(f.net_income, 0), 2)                    AS cash_conversion,
    -- growth vs previous year (LAG) and 3-year revenue CAGR
    ROUND(f.revenue / NULLIF(LAG(f.revenue) OVER w, 0) - 1, 4)   AS revenue_growth_yoy,
    ROUND(f.net_income / NULLIF(LAG(f.net_income) OVER w, 0) - 1, 4) AS net_income_growth_yoy,
    ROUND((POWER(f.revenue / NULLIF(LAG(f.revenue, 3) OVER w, 0), 1.0/3) - 1)::NUMERIC, 4)
                                                                  AS revenue_cagr_3y,
    -- previous-year helper to detect gaps in the series
    LAG(f.fiscal_year) OVER w                                     AS prev_fiscal_year
FROM mv_financials f
WINDOW w AS (PARTITION BY f.cik ORDER BY f.fiscal_year);

-- DuPont: ROE = net margin x asset turnover x equity multiplier ---------
-- main_roe_driver = the lever with the biggest relative change vs last year
CREATE VIEW v_dupont AS
WITH d AS (
    SELECT ticker, fiscal_year,
           net_income / NULLIF(revenue, 0)       AS nm,
           revenue    / NULLIF(total_assets, 0)  AS at,
           total_assets / NULLIF(equity, 0)      AS em,
           LAG(net_income / NULLIF(revenue, 0)) OVER w     AS nm_prev,
           LAG(revenue    / NULLIF(total_assets, 0)) OVER w AS at_prev,
           LAG(total_assets / NULLIF(equity, 0)) OVER w    AS em_prev,
           net_income, equity
    FROM mv_financials
    WHERE equity > 0
    WINDOW w AS (PARTITION BY cik ORDER BY fiscal_year)
), chg AS (
    SELECT d.*,
           ABS(nm / NULLIF(nm_prev, 0) - 1) AS c_margin,
           ABS(at / NULLIF(at_prev, 0) - 1) AS c_turnover,
           ABS(em / NULLIF(em_prev, 0) - 1) AS c_leverage
    FROM d
)
SELECT ticker, fiscal_year,
       ROUND(nm, 4) AS net_margin,
       ROUND(at, 3) AS asset_turnover,
       ROUND(em, 3) AS equity_multiplier,
       ROUND(nm * at * em, 4) AS roe,
       CASE
           WHEN nm_prev IS NULL THEN NULL
           WHEN c_margin   >= GREATEST(c_turnover, c_leverage) THEN 'margin'
           WHEN c_turnover >= c_leverage                       THEN 'turnover'
           ELSE 'leverage'
       END AS main_roe_driver
FROM chg;
