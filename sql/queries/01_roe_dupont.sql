-- Q1: Who earns the highest return on equity, and is it margin, turnover or leverage?
SET search_path = fw, public;
SELECT d.ticker, d.fiscal_year, d.roe, d.net_margin, d.asset_turnover, d.equity_multiplier, d.main_roe_driver
FROM v_dupont d
JOIN (SELECT ticker, MAX(fiscal_year) AS y FROM v_dupont GROUP BY ticker) m
  ON m.ticker = d.ticker AND m.y = d.fiscal_year
ORDER BY d.roe DESC NULLS LAST;
