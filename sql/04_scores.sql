-- =====================================================================
-- 04_scores.sql  |  Piotroski F-Score and Altman Z''-Score
-- =====================================================================
SET search_path = fw, public;

-- Piotroski F-Score (2000): 9 binary signals of financial strength.
-- Uses a self-join on fiscal_year - 1 (not LAG) so a missing year yields
-- NULL signals instead of a wrong comparison. Year-end balances are used
-- (stated simplification).
--
-- Some companies do not report cost of revenue (Exxon, UPS), so a signal
-- can be NULL. The score is the number of signals passed; f_signals says
-- how many could be computed; f_ratio = f_score / f_signals is comparable
-- across companies and is NULL when fewer than 7 signals are available.
CREATE VIEW v_piotroski AS
WITH s AS (
    SELECT c.ticker, c.sector, c.fiscal_year,
        (c.net_income / c.total_assets > 0)                                            AS f1_roa_positive,
        (c.cfo > 0)                                                                    AS f2_cfo_positive,
        (c.net_income / c.total_assets > p.net_income / p.total_assets)                AS f3_roa_improving,
        (c.cfo > c.net_income)                                                         AS f4_accruals_low,
        (c.long_term_debt / c.total_assets < p.long_term_debt / p.total_assets)        AS f5_leverage_down,
        (c.current_assets / NULLIF(c.current_liabilities, 0)
           > p.current_assets / NULLIF(p.current_liabilities, 0))                      AS f6_liquidity_up,
        (c.diluted_shares <= p.diluted_shares)                                         AS f7_no_dilution,
        (c.gross_profit / NULLIF(c.revenue, 0) > p.gross_profit / NULLIF(p.revenue, 0)) AS f8_gross_margin_up,
        (c.revenue / c.total_assets > p.revenue / p.total_assets)                      AS f9_turnover_up
    FROM mv_financials c
    JOIN mv_financials p ON p.cik = c.cik AND p.fiscal_year = c.fiscal_year - 1
), t AS (
    SELECT s.*,
        COALESCE(f1_roa_positive::INT,0) + COALESCE(f2_cfo_positive::INT,0) + COALESCE(f3_roa_improving::INT,0)
      + COALESCE(f4_accruals_low::INT,0) + COALESCE(f5_leverage_down::INT,0) + COALESCE(f6_liquidity_up::INT,0)
      + COALESCE(f7_no_dilution::INT,0)  + COALESCE(f8_gross_margin_up::INT,0) + COALESCE(f9_turnover_up::INT,0)
                                                                         AS f_score,
        (f1_roa_positive IS NOT NULL)::INT + (f2_cfo_positive IS NOT NULL)::INT + (f3_roa_improving IS NOT NULL)::INT
      + (f4_accruals_low IS NOT NULL)::INT + (f5_leverage_down IS NOT NULL)::INT + (f6_liquidity_up IS NOT NULL)::INT
      + (f7_no_dilution IS NOT NULL)::INT  + (f8_gross_margin_up IS NOT NULL)::INT + (f9_turnover_up IS NOT NULL)::INT
                                                                         AS f_signals
    FROM s
)
SELECT ticker, sector, fiscal_year, f_score, f_signals,
       CASE WHEN f_signals >= 7 THEN ROUND(f_score::NUMERIC / f_signals, 3) END AS f_ratio,
       CASE WHEN f_signals < 7                              THEN NULL
            WHEN f_score::NUMERIC / f_signals >= 0.85       THEN 'strong'   -- e.g. 8/9, 7/8
            WHEN f_score::NUMERIC / f_signals <= 0.25       THEN 'weak'     -- e.g. 2/9, 2/8
            ELSE 'neutral' END                                              AS f_label,
       f1_roa_positive, f2_cfo_positive, f3_roa_improving, f4_accruals_low,
       f5_leverage_down, f6_liquidity_up, f7_no_dilution, f8_gross_margin_up, f9_turnover_up
FROM t;

-- Altman Z''-Score (non-manufacturing / emerging-market variant).
-- Uses BOOK equity, so no market data is required:
--   Z'' = 6.56*X1 + 3.26*X2 + 6.72*X3 + 1.05*X4
--   X1 = working capital / assets      X2 = retained earnings / assets
--   X3 = EBIT / assets                 X4 = book equity / total liabilities
-- Zones: > 2.60 safe, 1.10-2.60 grey, < 1.10 distress.
-- EBIT proxy = operating income, else income before tax (see mv_financials).
-- Note: companies that buy back lots of stock (Apple) have low retained
-- earnings, which pulls X2 down; read the score as a screen, not a verdict.
CREATE VIEW v_altman AS
WITH z AS (
    SELECT ticker, sector, fiscal_year,
           6.56 * (current_assets - current_liabilities) / total_assets
         + 3.26 * retained_earnings / total_assets
         + 6.72 * ebit_proxy        / total_assets
         + 1.05 * equity / NULLIF(total_liabilities, 0)  AS z
    FROM mv_financials
    WHERE current_assets IS NOT NULL AND current_liabilities IS NOT NULL
      AND retained_earnings IS NOT NULL AND ebit_proxy IS NOT NULL
)
SELECT ticker, sector, fiscal_year,
       ROUND(z::NUMERIC, 2) AS z_score,
       CASE WHEN z > 2.6 THEN 'safe' WHEN z >= 1.1 THEN 'grey' ELSE 'distress' END AS zone
FROM z;
