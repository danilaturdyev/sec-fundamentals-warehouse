"""Tests run against synthetic fictional companies, so expected values are known exactly."""
import pytest
import synthetic as syn
import load_sec


# ---------- parser ----------------------------------------------------------
def test_parser_keeps_only_10k_and_wanted_tags():
    facts = syn.add_noise(syn.strong())
    facts["SomeUnmappedTag"] = {"units": {"USD": [{"end": "2024-12-31", "val": 1, "form": "10-K", "filed": "2025-02-15", "accn": "x"}]}}
    rows = load_sec.parse_companyfacts(syn.wrap("X", facts), 1, {"Revenues", "NetIncomeLoss"})
    assert {r[1] for r in rows} == {"Revenues", "NetIncomeLoss"}
    assert all(r[5].startswith("10-K") for r in rows)          # the 10-Q row is dropped
    assert not any(r[4] == 9_999_999 for r in rows)


def test_balance_sheet_facts_get_sentinel_start_date():
    rows = load_sec.parse_companyfacts(syn.wrap("X", syn.strong()), 1, {"Assets"})
    assert {r[2] for r in rows} == {"1900-01-01"}


# ---------- cleaning ---------------------------------------------------------
def test_one_row_per_company_year(q):
    assert q("SELECT COUNT(*) - COUNT(DISTINCT (cik, fiscal_year)) FROM fw.mv_financials")[0][0] == 0


def test_quarterly_rows_are_ignored(q):
    rev = q("SELECT revenue FROM fw.mv_financials WHERE ticker='STRG' AND fiscal_year=2024")[0][0]
    assert float(rev) == pytest.approx(1000 * 1.1 ** 4)


def test_restatement_uses_latest_filing(q):
    ni = q("SELECT net_income FROM fw.mv_financials WHERE ticker='STRG' AND fiscal_year=2023")[0][0]
    assert float(ni) == 100 + 30 * 3 + 1


def test_derived_fields(q):
    gp, fcf = q("SELECT gross_profit, free_cash_flow FROM fw.mv_financials WHERE ticker='STRG' AND fiscal_year=2020")[0]
    assert float(gp) == pytest.approx(400)                 # revenue - cost of revenue
    assert float(fcf) == pytest.approx(120 - 40)           # CFO - capex


# ---------- ratios ------------------------------------------------------------
def test_growth_and_cagr(q):
    yoy, cagr = q("SELECT revenue_growth_yoy, revenue_cagr_3y FROM fw.v_ratios WHERE ticker='STRG' AND fiscal_year=2023")[0]
    assert float(yoy) == pytest.approx(0.10, abs=1e-4)
    assert float(cagr) == pytest.approx(0.10, abs=1e-4)


def test_first_year_has_no_growth(q):
    assert q("SELECT revenue_growth_yoy FROM fw.v_ratios WHERE ticker='STRG' AND fiscal_year=2020")[0][0] is None


def test_dupont_identity_matches_roe(q):
    rows = q("SELECT d.roe, r.roe FROM fw.v_dupont d JOIN fw.v_ratios r USING (ticker, fiscal_year) WHERE d.ticker='STRG'")
    assert rows and all(abs(float(a) - float(b)) < 0.001 for a, b in rows)


# ---------- scores ---------------------------------------------------------------
def test_piotroski_strong_company_scores_nine(q):
    scores = [r[0] for r in q("SELECT f_score FROM fw.v_piotroski WHERE ticker='STRG' AND fiscal_year>=2021")]
    assert scores and all(s == 9 for s in scores)


def test_piotroski_weak_company_scores_near_zero(q):
    scores = [r[0] for r in q("SELECT f_score FROM fw.v_piotroski WHERE ticker='WEAK' AND fiscal_year>=2022")]
    assert scores and all(s <= 1 for s in scores)
    assert q("SELECT f_label FROM fw.v_piotroski WHERE ticker='WEAK' AND fiscal_year=2024")[0][0] == 'weak'


def test_piotroski_not_computed_across_a_gap(q):
    # GAPP has no 2022 row, so 2023 has no prior year and must not be scored
    assert q("SELECT COUNT(*) FROM fw.v_piotroski WHERE ticker='GAPP' AND fiscal_year=2023")[0][0] == 0


def test_altman_zones(q):
    assert q("SELECT zone FROM fw.v_altman WHERE ticker='STRG' AND fiscal_year=2024")[0][0] == 'safe'
    assert q("SELECT zone FROM fw.v_altman WHERE ticker='WEAK' AND fiscal_year=2024")[0][0] == 'distress'


def test_altman_formula_by_hand(q):
    # STRG 2020: WC=200, TA=1000, RE=300, EBIT=130, equity=600, TL=400
    expected = 6.56 * 0.2 + 3.26 * 0.3 + 6.72 * 0.13 + 1.05 * 600 / 400
    assert float(q("SELECT z_score FROM fw.v_altman WHERE ticker='STRG' AND fiscal_year=2020")[0][0]) == pytest.approx(expected, abs=0.01)


# ---------- ranking & data quality ----------------------------------------------------
def test_peer_ranking_orders_strong_above_weak(q):
    ranks = dict(q("SELECT ticker, rank_in_sector FROM fw.v_peer_ranking WHERE sector='Test Sector'"))
    assert ranks["STRG"] == 1 and ranks["WEAK"] == 2


def test_data_quality_flags_year_gap(q):
    rows = q("SELECT ticker, fiscal_year FROM fw.v_data_quality WHERE check_name='year_gap'")
    assert ("GAPP", 2023) in rows


def test_data_quality_clean_company_has_no_year_gap(q):
    assert q("SELECT COUNT(*) FROM fw.v_data_quality WHERE ticker='STRG' AND check_name='year_gap'")[0][0] == 0


def test_single_company_sector_gets_neutral_score(q):
    assert float(q("SELECT composite FROM fw.v_peer_ranking WHERE ticker='GAPP'")[0][0]) == 0.5


def test_fallback_tags_are_used(q):
    # ALTT reports net income as ProfitLoss and equity incl. non-controlling interest
    ni, eq = q("SELECT net_income, equity FROM fw.mv_financials WHERE ticker='ALTT' AND fiscal_year=2022")[0]
    assert ni is not None and eq is not None
    assert q("SELECT f_score FROM fw.v_piotroski WHERE ticker='ALTT' AND fiscal_year=2022")[0][0] == 9


def test_primary_tag_wins_over_fallback(q):
    # if both tags exist for the same year, priority 1 is used
    rows = q("""SELECT metric, tag FROM fw.dim_metric_map WHERE metric IN ('net_income','equity') ORDER BY metric, priority""")
    assert rows[0][1] == 'StockholdersEquity' and ('net_income', 'NetIncomeLoss') in rows


def test_missing_gross_profit_gives_eight_signals_not_null(q):
    score, signals, ratio, label = q(
        "SELECT f_score, f_signals, f_ratio, f_label FROM fw.v_piotroski WHERE ticker='NOOP' AND fiscal_year=2022")[0]
    assert (score, signals) == (8, 8)
    assert float(ratio) == 1.0 and label == 'strong'


def test_altman_falls_back_to_pretax_income(q):
    z_noop = q("SELECT z_score FROM fw.v_altman WHERE ticker='NOOP' AND fiscal_year=2024")[0][0]
    z_strg = q("SELECT z_score FROM fw.v_altman WHERE ticker='STRG' AND fiscal_year=2024")[0][0]
    assert z_noop == z_strg


def test_dq_reports_incomplete_fscore_for_latest_year(q):
    rows = q("SELECT ticker FROM fw.v_data_quality WHERE check_name='incomplete_fscore'")
    assert ("NOOP",) in rows and ("STRG",) not in rows


def test_quality_screen_returns_strong_safe_companies(q):
    with open("sql/queries/02_quality_screen.sql") as fh:
        rows = q(fh.read().split("SET search_path = fw, public;")[1])
    assert {"STRG", "NOOP"} <= {r[0] for r in rows} and "WEAK" not in {r[0] for r in rows}
