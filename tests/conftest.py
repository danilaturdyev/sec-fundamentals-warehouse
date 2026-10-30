import os
import sys
from pathlib import Path

import psycopg2
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "etl"))

import synthetic as syn            # noqa: E402
import load_sec                    # noqa: E402

DSN = os.getenv("TEST_DSN", "host=/tmp port=5433 user=postgres dbname=postgres")
SQL_FILES = ["01_schema", "02_clean_financials", "03_ratios", "04_scores", "05_peer_ranking", "06_data_quality"]

def _alt_tags(facts):
    """Same company but reporting under the fallback XBRL tags."""
    f = dict(facts)
    f["ProfitLoss"] = f.pop("NetIncomeLoss")
    f["StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"] = f.pop("StockholdersEquity")
    return f


def _no_opinc_no_cogs(facts):
    """Company like Exxon: no operating income, no cost of revenue; has pre-tax income."""
    f = dict(facts)
    f["IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest"] = f.pop("OperatingIncomeLoss")
    f.pop("CostOfRevenue")
    return f


FAKES = [  # cik, ticker, name, sector, facts
    (9999001, "STRG", "Strong Corp", "Test Sector", syn.add_noise(syn.strong())),
    (9999002, "WEAK", "Weak Corp", "Test Sector", syn.weak()),
    (9999004, "ALTT", "Alt Tags Corp", "Alt Sector", _alt_tags(syn.strong())),
    (9999005, "NOOP", "No Opinc Corp", "Noop Sector", _no_opinc_no_cogs(syn.strong())),
    (9999003, "GAPP", "Gap Corp", "Other Sector", syn.strong(years=[2020, 2021, 2023, 2024])),
]


@pytest.fixture(scope="session")
def conn():
    c = psycopg2.connect(DSN)
    with c.cursor() as cur:
        for name in SQL_FILES:
            cur.execute((ROOT / "sql" / f"{name}.sql").read_text())
        wanted = None
        cur.execute("SELECT DISTINCT tag FROM fw.dim_metric_map")
        wanted = {t for (t,) in cur.fetchall()}
        for cik, ticker, name, sector, facts in FAKES:
            cur.execute("INSERT INTO fw.dim_company VALUES (%s,%s,%s,%s)", (cik, ticker, name, sector))
    c.commit()
    for cik, ticker, name, sector, facts in FAKES:
        rows = load_sec.parse_companyfacts(syn.wrap(name, facts), cik, wanted)
        load_sec.insert_rows(c, cik, rows, "test")
    with c.cursor() as cur:
        cur.execute("REFRESH MATERIALIZED VIEW fw.mv_financials")
    c.commit()
    yield c
    c.close()


@pytest.fixture
def q(conn):
    def run(sql, params=None):
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    return run
