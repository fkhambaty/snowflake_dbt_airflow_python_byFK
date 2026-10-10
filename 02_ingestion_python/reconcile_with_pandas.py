#!/usr/bin/env python3
"""
Cross-system reconciliation with pandas  (Episode 4, "where Python beats dbt").

dbt can only see the warehouse. The question "does Snowflake agree with Postgres?" needs a
tool that can hold BOTH systems in memory and compare them. That is a DataFrame job.

    python reconcile_with_pandas.py                 # last 7 days, per day & currency
    python reconcile_with_pandas.py --days 30 --by branch

Checks performed
  1. Row counts per day/currency (or branch):  Postgres core.transactions  vs  MARTS.FCT_TRANSACTIONS
  2. Sum of POSTED amounts in local currency
  3. Lag: newest transaction_ts in Postgres vs newest in Snowflake  (= end-to-end freshness)

DataFrame concepts shown: read from two connections, merge (outer join), vectorised diff,
query/filter, groupby, formatting, assert-style exit codes for CI.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import uuid
import warnings

import pandas as pd
import psycopg2

from config import PG
from pg_to_snowflake import sf_connect

log = logging.getLogger("reconcile")
warnings.filterwarnings("ignore", message="pandas only supports SQLAlchemy")

ANALYTICS_DB = "MERIDIAN_ANALYTICS"
MARTS_SCHEMA = "MARTS"


def source_frame(days: int, by: str) -> pd.DataFrame:
    dim = "a.branch_id" if by == "branch" else "t.currency_code"
    sql = f"""
        SELECT (t.transaction_ts AT TIME ZONE 'UTC')::date AS txn_date,
               {dim}::text                                 AS grp,
               count(*)                                    AS src_rows,
               sum(t.amount) FILTER (WHERE t.status = 'POSTED') AS src_posted_amount,
               max(t.transaction_ts AT TIME ZONE 'UTC')    AS src_max_ts
        FROM core.transactions t
        JOIN core.accounts a USING (account_id)
        -- Compare the same complete UTC calendar dates that the Snowflake query uses.
        -- A rolling timestamp cutoff would compare only part of the oldest day in Postgres
        -- against the whole oldest day in Snowflake.
        WHERE (t.transaction_ts AT TIME ZONE 'UTC')::date >= current_date - {days}
          AND t.updated_at <= now() - interval '2 minutes'   -- give the pipeline a fair chance
        GROUP BY 1, 2
    """
    with psycopg2.connect(PG.dsn()) as conn:
        return pd.read_sql_query(sql, conn)


def warehouse_frame(days: int, by: str) -> pd.DataFrame:
    dim = "f.branch_id" if by == "branch" else "f.currency_code"
    sql = f"""
        SELECT f.transaction_date                                      AS txn_date,
               {dim}::string                                           AS grp,
               count(*)                                                AS wh_rows,
               sum(iff(f.status = 'POSTED', f.amount_local, 0))        AS wh_posted_amount,
               max(f.transaction_ts)                                   AS wh_max_ts
        FROM {ANALYTICS_DB}.{MARTS_SCHEMA}.FCT_TRANSACTIONS f
        WHERE f.transaction_date >= dateadd('day', -{days}, current_date())
        GROUP BY 1, 2
    """
    conn = sf_connect(
        user=os.getenv("SNOWFLAKE_DBT_USER", "MERIDIAN_DBT_SVC"),
        role="MERIDIAN_TRANSFORMER",
        warehouse=os.getenv("SNOWFLAKE_DBT_WAREHOUSE", "WH_TRANSFORM_XS"),
        query_tag="meridian_reconcile",
    )
    try:
        cur = conn.cursor()
        cur.execute(sql)
        df = cur.fetch_pandas_all()
    finally:
        conn.close()
    df.columns = [c.lower() for c in df.columns]
    return df


def reconcile(src: pd.DataFrame, wh: pd.DataFrame) -> pd.DataFrame:
    src["txn_date"] = pd.to_datetime(src["txn_date"]).dt.date
    wh["txn_date"] = pd.to_datetime(wh["txn_date"]).dt.date
    merged = src.merge(wh, on=["txn_date", "grp"], how="outer", indicator=True)
    merged[["src_rows", "wh_rows", "src_posted_amount", "wh_posted_amount"]] = (
        merged[["src_rows", "wh_rows", "src_posted_amount", "wh_posted_amount"]].fillna(0).astype(float)
    )
    merged["row_diff"] = merged["wh_rows"] - merged["src_rows"]
    merged["amount_diff"] = (merged["wh_posted_amount"] - merged["src_posted_amount"]).round(2)
    merged["ok"] = (merged["row_diff"] == 0) & (merged["amount_diff"].abs() < 0.01)
    return merged.sort_values(["txn_date", "grp"]).reset_index(drop=True)


def record_run(
    days: int,
    by: str,
    result: pd.DataFrame,
    lag_seconds: int | None,
) -> None:
    bad = result.loc[~result["ok"]]
    details = bad[
        ["txn_date", "grp", "row_diff", "amount_diff"]
    ].head(100).astype(str).to_dict(orient="records")
    conn = sf_connect(
        user=os.getenv("SNOWFLAKE_DBT_USER", "MERIDIAN_DBT_SVC"),
        role="MERIDIAN_TRANSFORMER",
        warehouse=os.getenv("SNOWFLAKE_DBT_WAREHOUSE", "WH_TRANSFORM_XS"),
        query_tag="meridian_reconcile_record",
    )
    try:
        cur = conn.cursor()
        cur.execute(
            """
            insert into MERIDIAN_RAW.CONTROL.RECONCILIATION_RUNS
                (run_id, days_checked, grouped_by, groups_checked, mismatch_groups,
                 max_abs_row_diff, max_abs_amount_diff, freshness_lag_s, status, details)
            select %s, %s, %s, %s, %s, %s, %s, %s, %s, parse_json(%s)
            """,
            (
                uuid.uuid4().hex,
                days,
                by,
                len(result),
                len(bad),
                int(result["row_diff"].abs().max()) if not result.empty else 0,
                float(result["amount_diff"].abs().max()) if not result.empty else 0.0,
                lag_seconds,
                "PASSED" if bad.empty else "FAILED",
                json.dumps(details),
            ),
        )
        conn.commit()
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--by", choices=["currency", "branch"], default="currency")
    parser.add_argument("--record", action="store_true", help="append the outcome to CONTROL.RECONCILIATION_RUNS")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    src = source_frame(args.days, args.by)
    wh = warehouse_frame(args.days, args.by)
    result = reconcile(src, wh)

    pd.set_option("display.width", 200)
    pd.set_option("display.max_rows", 500)
    cols = ["txn_date", "grp", "src_rows", "wh_rows", "row_diff", "src_posted_amount", "wh_posted_amount", "amount_diff", "ok"]
    log.info("\n%s", result[cols].to_string(index=False))

    lag = pd.to_datetime(src["src_max_ts"]).max() - pd.to_datetime(wh["wh_max_ts"]).max()
    log.info("\nend-to-end freshness lag: %s", lag)
    lag_seconds = None if pd.isna(lag) else int(lag.total_seconds())

    bad = result.loc[~result["ok"]]
    if args.record:
        record_run(args.days, args.by, result, lag_seconds)
    if bad.empty:
        log.info("RECONCILED: %d groups match", len(result))
        return 0
    log.error("MISMATCH in %d of %d groups", len(bad), len(result))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
