"""Cross-platform runner (works on Windows without make or psql).

    python run.py schema     create tables and views
    python run.py load       download SEC data and load it (needs SEC_USER_AGENT)
    python run.py dq         data-quality report
    python run.py q1 .. q5   example analytical queries
    python run.py export     save the scorecard to output/scorecard.csv (opens in Excel)
    python run.py all        schema + load + dq
"""
import csv
import glob
import os
import subprocess
import sys

import psycopg2

DSN = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/postgres")


def show(cur):
    if cur.description is None:
        return
    cols = [d[0] for d in cur.description]
    rows = [["" if v is None else str(v) for v in r] for r in cur.fetchall()]
    widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c) for i, c in enumerate(cols)]
    line = " | ".join(c.ljust(w) for c, w in zip(cols, widths))
    print(line)
    print("-+-".join("-" * w for w in widths))
    for r in rows:
        print(" | ".join(v.ljust(w) for v, w in zip(r, widths)))
    print(f"({len(rows)} rows)\n")


def run_sql_file(path, display=False):
    conn = psycopg2.connect(DSN)
    with conn, conn.cursor() as cur:
        cur.execute(open(path, encoding="utf-8").read())
        if display:
            show(cur)
    conn.close()


def schema():
    for f in sorted(glob.glob("sql/0*.sql")):
        print("running", f)
        run_sql_file(f)
    print("schema ready")


def load():
    if not os.getenv("SEC_USER_AGENT"):
        sys.exit("Set SEC_USER_AGENT first, e.g. PowerShell: $env:SEC_USER_AGENT=\"Your Name you@example.com\"")
    subprocess.check_call([sys.executable, "etl/load_sec.py", "--dsn", DSN, "--save-dir", "cache"])


def dq():
    conn = psycopg2.connect(DSN)
    with conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM fw.v_data_quality ORDER BY 1, 2")
        show(cur)
    conn.close()


EXPORT_SQL = """
SELECT k.ticker, k.sector, k.fiscal_year,
       r.revenue, r.net_income,
       r.gross_margin, r.operating_margin, r.net_margin, r.roe, r.revenue_cagr_3y,
       p.f_score, p.f_signals, p.f_label,
       a.z_score, a.zone,
       k.composite, k.rank_in_sector
FROM v_peer_ranking k
JOIN v_ratios r ON r.ticker = k.ticker AND r.fiscal_year = k.fiscal_year
LEFT JOIN v_piotroski p ON p.ticker = k.ticker AND p.fiscal_year = k.fiscal_year
LEFT JOIN v_altman a ON a.ticker = k.ticker AND a.fiscal_year = k.fiscal_year
ORDER BY k.sector, k.rank_in_sector
"""


def export():
    """Latest-year scorecard for every company, as a CSV that Excel opens directly."""
    os.makedirs("output", exist_ok=True)
    conn = psycopg2.connect(DSN)
    with conn, conn.cursor() as cur:
        cur.execute("SET search_path = fw, public")
        cur.execute(EXPORT_SQL)
        header = [d[0] for d in cur.description]
        rows = cur.fetchall()
    conn.close()
    path = os.path.join("output", "scorecard.csv")
    with open(path, "w", newline="", encoding="utf-8-sig") as fh:   # utf-8-sig: Excel-friendly
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(rows)
    print(f"saved {len(rows)} companies to {path}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    if cmd == "schema":
        schema()
    elif cmd == "load":
        load()
    elif cmd == "dq":
        dq()
    elif cmd == "export":
        export()
    elif cmd == "all":
        schema(); load(); dq()
    elif cmd in {"q1", "q2", "q3", "q4", "q5"}:
        run_sql_file(glob.glob(f"sql/queries/0{cmd[1]}_*.sql")[0], display=True)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
