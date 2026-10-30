# US Equity Fundamentals Warehouse (PostgreSQL)

A small data warehouse that pulls **real annual financial statements from SEC EDGAR (XBRL)** for 17 large US companies and turns them into analyst-grade metrics using SQL: ratios, DuPont decomposition, **Piotroski F-Score**, **Altman Z''-Score**, peer ranking and automated data-quality checks.

The point of the project is the SQL: the Python part only moves data in; every number you see is produced by views you can read and test.

## Architecture

```
SEC companyfacts API ──► etl/load_sec.py ──► raw_xbrl_fact        (long format, as filed)
                                               │
                         dim_metric_map ───────┤  tag → metric, priority
                                               ▼
                       v_annual_fact      only 10-K, only full-year flows, latest filing wins
                       v_annual_metric    one tag per metric by priority
                       mv_financials      one row per company-year (materialised, pivoted)
                                               │
        ┌───────────────┬──────────────────────┼───────────────┬────────────────┐
     v_ratios        v_dupont            v_piotroski       v_altman       v_data_quality
        └───────────────┴────────► v_peer_ranking ◄─────────┘
```

## SQL techniques used

| Technique | Where |
|---|---|
| Window functions: `LAG`, `ROW_NUMBER`, `PERCENT_RANK`, `NTILE`, `RANK` | ratios, ranking, cleaning |
| Conditional aggregation / pivoting with `FILTER` | `mv_financials` |
| CTE pipelines | DuPont, ranking |
| Materialised view + unique index | `mv_financials` |
| Self-join on `fiscal_year - 1` (safe against missing years) | Piotroski |
| `PERCENTILE_CONT` (median) | sector summary |
| Defensive maths: `NULLIF`, `COALESCE`, `NULLS FIRST` | everywhere |
| Constraints, foreign keys, audit table (`etl_run`) | schema |

## Modelling decisions

* **Restatements:** the same period appears in many filings. The latest filing wins (`ROW_NUMBER() ... ORDER BY filed DESC`).
* **Tag drift:** companies switch XBRL tags over time (`Revenues` → `RevenueFromContractWithCustomerExcludingAssessedTax`). `dim_metric_map` holds candidate tags with a priority.
* **Annual only:** quarterly and year-to-date facts inside a 10-K are removed by requiring a 350–380 day period.
* **Fiscal year** = calendar year of `period_end - 15 days`, so 52/53-week years ending in early January stay in the right year.
* **Piotroski** uses year-end rather than average balances (stated simplification). Companies that do not report cost of revenue (Exxon, UPS) cannot produce the gross-margin signal, so the score is shown as `f_score` out of `f_signals` available and compared via `f_ratio`; it is NULL if fewer than 7 signals exist.
* **Altman Z''** is the non-manufacturing variant with *book* equity, so no market data is needed. Operating income stands in for EBIT; if a company does not report it (Exxon, J&J) income before tax is used.
* Banks and insurers are deliberately excluded: current assets and gross profit do not exist for them and the scores would be meaningless.

## Quick start

```bash
docker compose up -d                        # PostgreSQL 16
pip install -r requirements.txt
export SEC_USER_AGENT="Your Name your.email@example.com"   # required by SEC
make schema                                 # tables + views
make load                                   # downloads ~17 companies (about 10 seconds)
make q2                                     # quality screen
make dq                                     # data-quality report
```

### Windows (no `make`, no Docker)

Install PostgreSQL 16 and Python, then in PowerShell from the project folder:

```powershell
pip install -r requirements.txt
$env:SEC_USER_AGENT = "Your Name your.email@example.com"
$env:DATABASE_URL = "postgresql://postgres:YOUR_PASSWORD@localhost:5432/postgres"
python run.py schema
python run.py load
python run.py dq
python run.py q2
```

## Example questions answered (`sql/queries/`)

1. Highest ROE, and is it driven by margin, asset turnover or leverage? (DuPont)
2. Which companies pass a quality screen: F-Score ≥ 7 **and** Altman zone "safe"?
3. Fastest 3-year revenue growers in each sector and their cash conversion.
4. Whose operating margin expanded three years in a row?
5. Sector scoreboard: median margin / ROE and Altman zones.

## Tests

`tests/` builds three **fictional** companies with known numbers (one that improves on all nine Piotroski signals, one that deteriorates, one with a missing year) and asserts exact results: F-Score 9 vs 0, the Altman formula by hand, restatement handling, 10-Q rows ignored, gap detection, ranking order.

```bash
export TEST_DSN="postgresql://postgres:postgres@localhost:5432/postgres"
make test
```
(The tests recreate the `fw` schema, so use a scratch database.)

## Known data issues (found by `make dq`)

* **Tag drift is real.** Caterpillar stopped using `NetIncomeLoss` after 2010 and reports `ProfitLoss`; P&G, J&J and Caterpillar report equity under a different tag than most companies. `dim_metric_map` therefore has fallback tags (lower priority). `ProfitLoss` includes non-controlling interests, so for such companies net income is slightly higher than "attributable to shareholders".
* **Old years can be patchy** (e.g. a gap in Pfizer's 2014-2015 series, and a balance-sheet mismatch for Microsoft FY2016 in the source data). The checks in `v_data_quality` flag these; they only affect early history.
* **Fiscal years differ** (Apple ends in September, Walmart and NVIDIA in January, Costco in August), so "latest year" is taken per company, never globally.

## Limitations

* Annual data only; scores are a screening tool, not investment advice.
* Operating income as EBIT proxy; year-end balances in Piotroski.
* XBRL tagging differs between companies; run `make dq` after each load and extend `dim_metric_map` when a company is flagged.

## Data source

SEC EDGAR `data.sec.gov` XBRL "companyfacts" API (public domain). Respect the fair-access policy (identify yourself, ≤10 requests/s).
