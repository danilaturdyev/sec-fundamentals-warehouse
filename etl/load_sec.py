"""Load annual XBRL facts from SEC EDGAR into PostgreSQL.

Usage:
    python etl/load_sec.py                      # download + load all companies in data/companies.csv
    python etl/load_sec.py --from-dir fixtures  # load previously saved companyfacts JSON (offline / tests)

SEC requires a descriptive User-Agent with contact details:
    export SEC_USER_AGENT="Your Name your.email@example.com"
Fair-access limit is 10 requests/second; this script sends ~1 per 0.2 s.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from pathlib import Path

import psycopg2
import psycopg2.extras
import requests

URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010d}.json"
INSTANT_START = "1900-01-01"          # sentinel for balance-sheet facts
UNIT_FOR_TAG_DEFAULT = ("USD", "shares")


def parse_companyfacts(payload: dict, cik: int, wanted_tags: set[str]) -> list[tuple]:
    """Flatten a SEC 'companyfacts' document into raw_xbrl_fact rows.

    Keeps only annual filings (10-K family) and only the tags we map to metrics.
    Pure function (no I/O) so it is easy to unit-test.
    """
    rows: list[tuple] = []
    gaap = payload.get("facts", {}).get("us-gaap", {})
    for tag in wanted_tags & gaap.keys():
        for unit, facts in gaap[tag].get("units", {}).items():
            if unit not in UNIT_FOR_TAG_DEFAULT:
                continue
            for f in facts:
                form = f.get("form", "")
                if not form.startswith("10-K"):
                    continue
                rows.append((
                    cik, tag,
                    f.get("start") or INSTANT_START,   # instants have no start date
                    f["end"], f["val"], form, f["filed"], f["accn"],
                ))
    return rows


def load_companies(conn, csv_path: Path) -> None:
    with conn.cursor() as cur, csv_path.open() as fh:
        for r in csv.DictReader(fh):
            cur.execute(
                """INSERT INTO fw.dim_company (cik, ticker, name, sector)
                   VALUES (%s, %s, %s, %s)
                   ON CONFLICT (cik) DO UPDATE
                   SET ticker = EXCLUDED.ticker, name = EXCLUDED.name, sector = EXCLUDED.sector""",
                (int(r["cik"]), r["ticker"], r["name"], r["sector"]),
            )
    conn.commit()


def insert_rows(conn, cik: int, rows: list[tuple], note: str) -> int:
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO fw.raw_xbrl_fact
               (cik, tag, period_start, period_end, value, form, filed, accession)
               VALUES %s ON CONFLICT DO NOTHING""",
            rows, page_size=5000,
        )
        cur.execute("INSERT INTO fw.etl_run (cik, rows_loaded, note) VALUES (%s, %s, %s)",
                    (cik, len(rows), note))
    conn.commit()
    return len(rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/postgres"))
    ap.add_argument("--companies", default="data/companies.csv")
    ap.add_argument("--from-dir", help="read CIK##########.json files from this folder instead of downloading")
    ap.add_argument("--save-dir", help="also save downloaded JSON here (cache)")
    args = ap.parse_args()

    conn = psycopg2.connect(args.dsn)
    load_companies(conn, Path(args.companies))
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT tag FROM fw.dim_metric_map")
        wanted = {t for (t,) in cur.fetchall()}
        cur.execute("SELECT cik, ticker, name FROM fw.dim_company ORDER BY ticker")
        companies = cur.fetchall()

    ua = os.getenv("SEC_USER_AGENT")
    if not args.from_dir and not ua:
        sys.exit("Set SEC_USER_AGENT, e.g. export SEC_USER_AGENT='Your Name you@example.com'")

    total = 0
    for cik, ticker, name in companies:
        fname = f"CIK{cik:010d}.json"
        if args.from_dir:
            path = Path(args.from_dir) / fname
            if not path.exists():
                print(f"{ticker:6} skipped (no file)")
                continue
            payload = json.loads(path.read_text())
        else:
            resp = requests.get(URL.format(cik=cik), headers={"User-Agent": ua}, timeout=30)
            resp.raise_for_status()
            payload = resp.json()
            if args.save_dir:
                Path(args.save_dir).mkdir(parents=True, exist_ok=True)
                (Path(args.save_dir) / fname).write_text(json.dumps(payload))
            time.sleep(0.2)
        # sanity check: the CIK must really be the company we think it is
        entity = payload.get("entityName", "")
        if name.split()[0].lower() not in entity.lower():
            print(f"WARNING {ticker}: SEC says '{entity}', expected '{name}'")
        n = insert_rows(conn, cik, parse_companyfacts(payload, cik, wanted), "from-dir" if args.from_dir else "sec-api")
        total += n
        print(f"{ticker:6} {n:6} facts")
    with conn.cursor() as cur:
        cur.execute("REFRESH MATERIALIZED VIEW fw.mv_financials")
    conn.commit()
    print(f"done: {total} facts loaded, mv_financials refreshed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
