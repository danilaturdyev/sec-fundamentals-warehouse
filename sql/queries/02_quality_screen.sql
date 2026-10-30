-- Q2: Quality screen - at least 6/9 Piotroski signals AND a "safe" Altman zone,
-- using each company's own latest fiscal year (fiscal years end in different months)
SET search_path = fw, public;
WITH latest AS (
    SELECT ticker, MAX(fiscal_year) AS fy FROM v_piotroski GROUP BY ticker
)
SELECT p.ticker, p.fiscal_year, p.f_score || '/' || p.f_signals AS f_score,
       a.z_score, a.zone
FROM v_piotroski p
JOIN latest l ON l.ticker = p.ticker AND l.fy = p.fiscal_year
JOIN v_altman a ON a.ticker = p.ticker AND a.fiscal_year = p.fiscal_year
WHERE p.f_ratio >= 0.66 AND a.zone = 'safe'
ORDER BY p.f_ratio DESC, a.z_score DESC;
