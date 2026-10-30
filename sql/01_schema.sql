-- =====================================================================
-- 01_schema.sql  |  Core tables
-- Layers:  raw_xbrl_fact (as loaded)  ->  views/materialised view (clean)
--          ->  analytics views (ratios, scores, rankings)
-- =====================================================================
DROP SCHEMA IF EXISTS fw CASCADE;
CREATE SCHEMA fw;
SET search_path = fw, public;

-- Companies in scope --------------------------------------------------
CREATE TABLE dim_company (
    cik      BIGINT PRIMARY KEY,
    ticker   TEXT   NOT NULL UNIQUE,
    name     TEXT   NOT NULL,
    sector   TEXT   NOT NULL
);

-- Which XBRL (us-gaap) tags feed which metric, in priority order. ------
-- Companies change tags over time (e.g. Revenues -> RevenueFromContract...)
-- so each metric has several candidate tags; the lowest priority wins.
CREATE TABLE dim_metric_map (
    metric        TEXT    NOT NULL,
    tag           TEXT    NOT NULL,
    priority      INT     NOT NULL CHECK (priority > 0),
    is_flow       BOOLEAN NOT NULL,   -- TRUE = period (income / cash flow), FALSE = point in time (balance sheet)
    PRIMARY KEY (metric, tag)
);

-- Raw facts exactly as SEC reports them (long format) -----------------
-- period_start = DATE '1900-01-01' for point-in-time (balance sheet) facts,
-- so that it can take part in the primary key.
CREATE TABLE raw_xbrl_fact (
    cik           BIGINT  NOT NULL REFERENCES dim_company(cik),
    tag           TEXT    NOT NULL,
    period_start  DATE    NOT NULL,
    period_end    DATE    NOT NULL,
    value         NUMERIC NOT NULL,
    form          TEXT    NOT NULL,
    filed         DATE    NOT NULL,
    accession     TEXT    NOT NULL,
    PRIMARY KEY (cik, tag, period_start, period_end, accession)
);
CREATE INDEX ix_raw_lookup ON raw_xbrl_fact (cik, tag, period_end);

-- Load audit trail -----------------------------------------------------
CREATE TABLE etl_run (
    run_id      BIGSERIAL PRIMARY KEY,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    cik         BIGINT,
    rows_loaded INT,
    note        TEXT
);

-- Metric map seed ------------------------------------------------------
INSERT INTO dim_metric_map (metric, tag, priority, is_flow) VALUES
 ('revenue',            'Revenues',                                              1, TRUE),
 ('revenue',            'RevenueFromContractWithCustomerExcludingAssessedTax',   2, TRUE),
 ('revenue',            'SalesRevenueNet',                                       3, TRUE),
 ('cost_of_revenue',    'CostOfRevenue',                                         1, TRUE),
 ('cost_of_revenue',    'CostOfGoodsAndServicesSold',                            2, TRUE),
 ('gross_profit',       'GrossProfit',                                           1, TRUE),
 ('operating_income',   'OperatingIncomeLoss',                                   1, TRUE),
 ('net_income',         'NetIncomeLoss',                                         1, TRUE),
 ('net_income',         'ProfitLoss',                                            2, TRUE),   -- e.g. Caterpillar after 2010
 ('net_income',         'NetIncomeLossAvailableToCommonStockholdersBasic',       3, TRUE),
 ('pretax_income',      'IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest', 1, TRUE),
 ('pretax_income',      'IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments', 2, TRUE),
 ('diluted_shares',     'WeightedAverageNumberOfDilutedSharesOutstanding',       1, TRUE),
 ('cfo',                'NetCashProvidedByUsedInOperatingActivities',            1, TRUE),
 ('capex',              'PaymentsToAcquirePropertyPlantAndEquipment',            1, TRUE),
 ('capex',              'PaymentsToAcquireProductiveAssets',                     2, TRUE),
 ('total_assets',       'Assets',                                                1, FALSE),
 ('current_assets',     'AssetsCurrent',                                         1, FALSE),
 ('current_liabilities','LiabilitiesCurrent',                                    1, FALSE),
 ('total_liabilities',  'Liabilities',                                           1, FALSE),
 ('long_term_debt',     'LongTermDebtNoncurrent',                                1, FALSE),
 ('long_term_debt',     'LongTermDebt',                                          2, FALSE),
 ('equity',             'StockholdersEquity',                                    1, FALSE),
 ('equity',             'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest', 2, FALSE),
 ('retained_earnings',  'RetainedEarningsAccumulatedDeficit',                    1, FALSE);
