-- =====================================================================
-- 05_peer_ranking.sql  |  Rank companies against sector peers
-- =====================================================================
SET search_path = fw, public;

-- Latest fiscal year available for each company, then percentile ranks
-- inside the sector. composite = average of four percentile ranks
-- (quality, profitability, growth, cash generation).
CREATE VIEW v_peer_ranking AS
WITH latest AS (
    SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.cik ORDER BY r.fiscal_year DESC) AS rn
    FROM v_ratios r
), cur AS (
    SELECT l.*, p.f_score, p.f_signals, p.f_ratio, a.z_score
    FROM latest l
    LEFT JOIN v_piotroski p ON p.ticker = l.ticker AND p.fiscal_year = l.fiscal_year
    LEFT JOIN v_altman    a ON a.ticker = l.ticker AND a.fiscal_year = l.fiscal_year
    WHERE l.rn = 1
), pr AS (
    SELECT ticker, sector, fiscal_year, roe, operating_margin, revenue_cagr_3y, fcf_margin, f_score, f_signals, f_ratio, z_score,
           -- NULLS FIRST: a missing metric ranks last, never first.
           -- A sector with a single company gets a neutral 0.5.
           CASE WHEN COUNT(*) OVER (PARTITION BY sector) = 1 THEN 0.5
                ELSE PERCENT_RANK() OVER (PARTITION BY sector ORDER BY f_ratio NULLS FIRST) END          AS p_quality,
           CASE WHEN COUNT(*) OVER (PARTITION BY sector) = 1 THEN 0.5
                ELSE PERCENT_RANK() OVER (PARTITION BY sector ORDER BY operating_margin NULLS FIRST) END AS p_profit,
           CASE WHEN COUNT(*) OVER (PARTITION BY sector) = 1 THEN 0.5
                ELSE PERCENT_RANK() OVER (PARTITION BY sector ORDER BY revenue_cagr_3y NULLS FIRST) END  AS p_growth,
           CASE WHEN COUNT(*) OVER (PARTITION BY sector) = 1 THEN 0.5
                ELSE PERCENT_RANK() OVER (PARTITION BY sector ORDER BY fcf_margin NULLS FIRST) END       AS p_cash
    FROM cur
)
SELECT ticker, sector, fiscal_year, f_score, f_signals, z_score,
       operating_margin, roe, revenue_cagr_3y, fcf_margin,
       ROUND(((p_quality + p_profit + p_growth + p_cash) / 4)::NUMERIC, 3)      AS composite,
       RANK() OVER (PARTITION BY sector
                    ORDER BY (p_quality + p_profit + p_growth + p_cash) DESC)   AS rank_in_sector,
       NTILE(4) OVER (ORDER BY (p_quality + p_profit + p_growth + p_cash) DESC) AS overall_quartile
FROM pr;
