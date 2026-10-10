#!/usr/bin/env python3
"""
Keeps the OLTP system alive by calling core.sim_tick() on a timer.

    python simulate_activity.py                     # 500 transactions every 5 seconds
    python simulate_activity.py --txn 2000 --every 2 # ~1000 txn/s: enough to stress the pipeline
    python simulate_activity.py --burst 50000        # one big spike then exit (late-arriving data demo)

All the business logic lives in SQL (01_source_postgres/05_dml_simulator_functions.sql);
this script is only a clock. Keeping logic in the database makes the lesson honest: the
warehouse never sees "Python-shaped" data, it sees whatever the core banking system did.
"""
from __future__ import annotations

import argparse
import logging
import sys
import time

import psycopg2

from config import PG

log = logging.getLogger("simulate")


def tick(conn, txn: int) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT step, rows_affected FROM core.sim_tick(%s)", (txn,))
        rows = cur.fetchall()
    conn.commit()
    log.info(" | ".join(f"{step}={n}" for step, n in rows))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--txn", type=int, default=500, help="transactions per tick")
    parser.add_argument("--every", type=float, default=5.0, help="seconds between ticks")
    parser.add_argument("--burst", type=int, help="insert this many transactions once and exit")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

    conn = psycopg2.connect(PG.dsn())
    try:
        if args.burst:
            with conn.cursor() as cur:
                cur.execute("SELECT core.sim_post_transactions(%s)", (args.burst,))
                log.info("burst inserted %s transactions", cur.fetchone()[0])
            conn.commit()
            return 0
        log.info("simulating: %d transactions every %.1fs (Ctrl+C to stop)", args.txn, args.every)
        while True:
            started = time.monotonic()
            tick(conn, args.txn)
            time.sleep(max(0.0, args.every - (time.monotonic() - started)))
    except KeyboardInterrupt:
        log.info("stopped")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
