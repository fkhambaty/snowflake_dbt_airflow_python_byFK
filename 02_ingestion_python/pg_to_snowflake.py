#!/usr/bin/env python3
"""
Micro-batch replication: PostgreSQL  ->  Parquet  ->  Snowflake internal stage  ->  COPY INTO raw.

    python pg_to_snowflake.py                 # one pass over every table (first run = full load)
    python pg_to_snowflake.py --loop 300      # run every 5 minutes forever
    python pg_to_snowflake.py --tables core.transactions,ref.fx_rates
    python pg_to_snowflake.py --reset-watermark core.customers   # force a full reload of one table
    python pg_to_snowflake.py --tables core.transactions \
        --since 2026-09-01T00:00:00Z --until 2026-09-02T00:00:00Z  # replay, watermark unchanged

Design (each point is a teaching moment, see course/COURSE_GUIDE_TEXT.html -> Module 4):

  1. WATERMARK CDC   : pull rows WHERE cursor > last_watermark AND cursor <= now() - lag.
                       The lag protects against long-running source transactions whose
                       updated_at is older than their commit time.
  2. APPEND-ONLY RAW : we never UPDATE in raw. Every version of a row lands as a new VARIANT
                       record with _extracted_at/_batch_id. dbt staging picks the latest.
  3. VARIANT RAW     : schema drift in Postgres never breaks the load. Typing happens in dbt.
  4. IDEMPOTENT      : a batch that fails before the watermark is advanced simply re-runs and
                       re-lands the same rows; dedupe downstream makes that harmless.
  5. PARQUET         : columnar, typed (DECIMAL stays DECIMAL), compressed, splittable.
  6. CONTROL TABLES  : WATERMARKS + LOAD_LOG in Snowflake = observability for free.
"""
from __future__ import annotations

import argparse
import logging
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import psycopg2
import psycopg2.extras
import pyarrow as pa
import pyarrow.parquet as pq
import snowflake.connector
from cryptography.hazmat.primitives import serialization

from config import INGEST, PG, SF, TABLES, SourceTable

log = logging.getLogger("ingest")

# PostgreSQL type OIDs -> Arrow types. Anything unknown becomes a string (never lose data).
PG_OID_TO_ARROW: dict[int, pa.DataType] = {
    16: pa.bool_(),
    20: pa.int64(),
    21: pa.int64(),
    23: pa.int64(),
    700: pa.float64(),
    701: pa.float64(),
    1700: pa.decimal128(38, 10),
    1082: pa.date32(),
    1114: pa.timestamp("us"),
    1184: pa.timestamp("us"),   # timestamptz -> normalised to naive UTC below
    25: pa.string(),
    1042: pa.string(),
    1043: pa.string(),
    2950: pa.string(),          # uuid
    3802: pa.string(),          # jsonb -> string; parse with PARSE_JSON in Snowflake if needed
}
TIMESTAMP_OIDS = {1114, 1184}


# ----------------------------------------------------------------------------- connections
def pg_connect():
    conn = psycopg2.connect(PG.dsn())
    conn.set_session(readonly=True, autocommit=False)
    return conn


def sf_connect(
    *,
    user: str | None = None,
    role: str | None = None,
    warehouse: str | None = None,
    query_tag: str = "meridian_ingest",
):
    kwargs = dict(
        account=SF.account,
        user=user or SF.user,
        role=role or SF.role,
        warehouse=warehouse or SF.warehouse,
        database=SF.raw_database,
        schema=SF.control_schema,
        session_parameters={"QUERY_TAG": query_tag, "TIMEZONE": "UTC"},
    )
    if SF.private_key_path:
        key_path = Path(SF.private_key_path).expanduser()
        passphrase = SF.private_key_passphrase.encode() or None
        private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=passphrase)
        kwargs["private_key"] = private_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    else:
        kwargs["password"] = SF.password
    return snowflake.connector.connect(**kwargs)


# ----------------------------------------------------------------------------- control tables
def control_fqn(name: str) -> str:
    return f"{SF.raw_database}.{SF.control_schema}.{name}"


def get_watermark(sf_cur, table: SourceTable) -> datetime:
    sf_cur.execute(
        f"SELECT last_watermark FROM {control_fqn('WATERMARKS')} WHERE table_name = %s",
        (table.qualified_source,),
    )
    row = sf_cur.fetchone()
    if row and row[0]:
        return row[0].replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(INGEST.initial_watermark).replace(tzinfo=timezone.utc)


def set_watermark(sf_cur, table: SourceTable, watermark: datetime, batch_id: str) -> None:
    sf_cur.execute(
        f"""
        MERGE INTO {control_fqn('WATERMARKS')} t
        USING (SELECT %s AS table_name, %s::TIMESTAMP_NTZ AS last_watermark, %s AS last_batch_id) s
           ON t.table_name = s.table_name
        WHEN MATCHED THEN UPDATE SET last_watermark = s.last_watermark, last_batch_id = s.last_batch_id, updated_at = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (table_name, last_watermark, last_batch_id, updated_at)
             VALUES (s.table_name, s.last_watermark, s.last_batch_id, CURRENT_TIMESTAMP())
        """,
        (table.qualified_source, watermark.astimezone(timezone.utc).replace(tzinfo=None), batch_id),
    )


def log_batch(sf_cur, batch_id: str, table: SourceTable, low: datetime, high: datetime,
              rows: int, files: int, started: datetime, status: str, error: str | None) -> None:
    sf_cur.execute(
        f"""
        INSERT INTO {control_fqn('LOAD_LOG')}
            (batch_id, table_name, low_watermark, high_watermark, rows_extracted, files_loaded,
             started_at, finished_at, status, error_message)
        SELECT %s, %s, %s::TIMESTAMP_NTZ, %s::TIMESTAMP_NTZ, %s, %s, %s::TIMESTAMP_NTZ, CURRENT_TIMESTAMP(), %s, %s
        """,
        (batch_id, table.qualified_source, _naive(low), _naive(high), rows, files, _naive(started), status, error),
    )


def _naive(ts: datetime) -> datetime:
    return ts.astimezone(timezone.utc).replace(tzinfo=None)


def parse_utc_timestamp(value: str) -> datetime:
    """Parse an ISO-8601 boundary and require an unambiguous timezone."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"timezone required in {value!r}; use Z or an explicit offset")
    return parsed.astimezone(timezone.utc)


def replay_window(since: str | None, until: str | None) -> tuple[datetime, datetime] | None:
    if since is None and until is None:
        return None
    if since is None or until is None:
        raise ValueError("--since and --until must be supplied together")
    low, high = parse_utc_timestamp(since), parse_utc_timestamp(until)
    if low >= high:
        raise ValueError("--since must be earlier than --until")
    return low, high


def should_advance_watermark(window: tuple[datetime, datetime] | None) -> bool:
    """Historical replay is additive and must never move normal pipeline progress."""
    return window is None


# ----------------------------------------------------------------------------- extract
def build_arrow_schema(description, extra: dict[str, pa.DataType]) -> pa.Schema:
    fields = [pa.field(col.name, PG_OID_TO_ARROW.get(col.type_code, pa.string())) for col in description]
    fields += [pa.field(name, dtype) for name, dtype in extra.items()]
    return pa.schema(fields)


def normalise_dataframe(df: pd.DataFrame, description) -> pd.DataFrame:
    """
    Dataframe lesson: make the chunk Parquet-friendly and timezone-unambiguous.
      * TIMESTAMPTZ -> naive UTC. The warehouse standardises on UTC; local time is a presentation concern.
      * unknown types -> str so nothing is silently dropped.
    """
    for col in description:
        if col.type_code in TIMESTAMP_OIDS and col.name in df.columns:
            df[col.name] = pd.to_datetime(df[col.name], utc=True).dt.tz_localize(None)
        elif col.type_code not in PG_OID_TO_ARROW and col.name in df.columns:
            df[col.name] = df[col.name].astype("string")
    return df


def extract_table(pg_conn, table: SourceTable, low: datetime, high: datetime,
                  batch_id: str, extracted_at: datetime, out_dir: Path) -> tuple[list[Path], int, datetime | None]:
    """Stream rows from Postgres with a server-side cursor and write N Parquet files."""
    sql = (
        f"SELECT * FROM {table.qualified_source} "
        f"WHERE {table.cursor_column} > %s AND {table.cursor_column} <= %s "
        f"ORDER BY {table.cursor_column}"
    )
    files: list[Path] = []
    total_rows = 0
    max_cursor: datetime | None = None
    extra_cols = {"_extracted_at": pa.timestamp("us"), "_batch_id": pa.string()}

    with pg_conn.cursor(name=f"ingest_{table.name}_{batch_id[:8]}") as cur:   # named = server-side cursor
        cur.itersize = INGEST.chunk_rows
        cur.execute(sql, (low, high))
        part = 0
        schema = None
        while True:
            rows = cur.fetchmany(INGEST.chunk_rows)
            if not rows:
                break
            if schema is None:
                schema = build_arrow_schema(cur.description, extra_cols)
            df = pd.DataFrame(rows, columns=[c.name for c in cur.description])
            df = normalise_dataframe(df, cur.description)
            df["_extracted_at"] = _naive(extracted_at)
            df["_batch_id"] = batch_id

            chunk_max = df[table.cursor_column].max()
            chunk_max = pd.Timestamp(chunk_max).to_pydatetime().replace(tzinfo=timezone.utc)
            max_cursor = max(max_cursor, chunk_max) if max_cursor else chunk_max

            path = out_dir / f"{table.name}_{batch_id}_{part:05d}.parquet"
            arrow_table = pa.Table.from_pandas(df, schema=schema, preserve_index=False, safe=False)
            pq.write_table(arrow_table, path, compression="snappy")
            files.append(path)
            total_rows += len(df)
            part += 1
            log.debug("  %s part %d: %d rows", table.qualified_source, part, len(df))
    pg_conn.rollback()  # end the read-only snapshot
    return files, total_rows, max_cursor


# ----------------------------------------------------------------------------- load
def load_files(sf_cur, table: SourceTable, files: list[Path], batch_id: str, extracted_at: datetime) -> int:
    target = f"{SF.raw_database}.{table.snowflake_schema}.{table.snowflake_table}"
    stage = f"@{SF.raw_database}.{table.snowflake_schema}.{SF.stage_name}/{table.name}/{batch_id}/"

    # PUT is a client-side command (upload to the internal stage). One wildcard PUT uploads every
    # part file of this batch in parallel threads. Parquet is already compressed -> AUTO_COMPRESS=FALSE.
    pattern = files[0].parent / f"{table.name}_{batch_id}_*.parquet"
    sf_cur.execute(f"PUT file://{pattern} {stage} AUTO_COMPRESS=FALSE OVERWRITE=TRUE PARALLEL=8")

    sf_cur.execute(
        f"""
        COPY INTO {target} (record, _extracted_at, _batch_id, _source_file)
        FROM (
            SELECT $1, %s::TIMESTAMP_NTZ, %s, METADATA$FILENAME
            FROM {stage}
        )
        FILE_FORMAT = (FORMAT_NAME = '{SF.raw_database}.{SF.control_schema}.FF_PARQUET')
        ON_ERROR = ABORT_STATEMENT
        PURGE = TRUE
        """,
        (_naive(extracted_at), batch_id),
    )
    loaded = sum(int(r[3]) for r in sf_cur.fetchall() if len(r) > 3 and str(r[1]).upper() == "LOADED")
    return loaded


# ----------------------------------------------------------------------------- orchestration
def process_table(
    pg_conn,
    sf_conn,
    table: SourceTable,
    out_dir: Path,
    window: tuple[datetime, datetime] | None = None,
) -> bool:
    sf_cur = sf_conn.cursor()
    started = datetime.now(timezone.utc)
    batch_id = uuid.uuid4().hex
    low, high = window or (
        get_watermark(sf_cur, table),
        started - timedelta(seconds=INGEST.lag_seconds),
    )
    replay = window is not None
    files: list[Path] = []
    try:
        files, rows, max_cursor = extract_table(pg_conn, table, low, high, batch_id, started, out_dir)
        if rows == 0:
            log.info("%-28s no changes since %s", table.qualified_source, low.isoformat(timespec="seconds"))
            status = "REPLAY_NO_CHANGES" if replay else "NO_CHANGES"
            log_batch(sf_cur, batch_id, table, low, high, 0, 0, started, status, None)
            sf_conn.commit()
            return True
        loaded = load_files(sf_cur, table, files, batch_id, started)
        # A replay is additive: staging dedupes it, but normal forward progress is untouched.
        if should_advance_watermark(window):
            # Advance to what we saw, never `high`: a quiet table keeps its watermark.
            set_watermark(sf_cur, table, max_cursor, batch_id)
        status = "REPLAY_SUCCESS" if replay else "SUCCESS"
        log_batch(sf_cur, batch_id, table, low, high, rows, len(files), started, status, None)
        sf_conn.commit()
        progress = "watermark unchanged (replay)" if replay else f"watermark -> {max_cursor.isoformat(timespec='seconds')}"
        log.info("%-28s %8d rows  %3d files  %s  (%.1fs)",
                 table.qualified_source, loaded, len(files), progress,
                 (datetime.now(timezone.utc) - started).total_seconds())
        return True
    except Exception as exc:  # noqa: BLE001 - we want to log any failure and keep other tables going
        sf_conn.rollback()
        log.exception("%s FAILED: %s", table.qualified_source, exc)
        try:
            log_batch(sf_cur, batch_id, table, low, high, 0, len(files), started, "FAILED", str(exc)[:4000])
            sf_conn.commit()
        except Exception:  # noqa: BLE001
            log.error("could not write LOAD_LOG for %s", table.qualified_source)
        return False
    finally:
        for path in files:
            path.unlink(missing_ok=True)
        sf_cur.close()


def run_once(
    selected: list[SourceTable],
    window: tuple[datetime, datetime] | None = None,
) -> None:
    INGEST.local_dir.mkdir(parents=True, exist_ok=True)
    pg_conn = pg_connect()
    sf_conn = sf_connect()
    try:
        failed = [
            table.qualified_source
            for table in selected
            if not process_table(pg_conn, sf_conn, table, INGEST.local_dir, window)
        ]
        if failed:
            raise RuntimeError(f"{len(failed)} table(s) failed: {', '.join(failed)}")
    finally:
        pg_conn.close()
        sf_conn.close()


def reset_watermark(table: SourceTable) -> None:
    sf_conn = sf_connect()
    try:
        cur = sf_conn.cursor()
        cur.execute(f"DELETE FROM {control_fqn('WATERMARKS')} WHERE table_name = %s", (table.qualified_source,))
        sf_conn.commit()
        log.info("watermark reset for %s (next run = full reload; raw keeps old versions, dbt dedupes)",
                 table.qualified_source)
    finally:
        sf_conn.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tables", help="comma separated schema.table list (default: all)")
    parser.add_argument("--loop", type=int, metavar="SECONDS", help="repeat forever every N seconds")
    parser.add_argument("--reset-watermark", metavar="SCHEMA.TABLE", help="delete the watermark and exit")
    parser.add_argument("--since", help="inclusive replay lower bound in ISO-8601 with timezone")
    parser.add_argument("--until", help="inclusive replay upper bound in ISO-8601 with timezone")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    by_name = {t.qualified_source: t for t in TABLES}
    try:
        window = replay_window(args.since, args.until)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    if args.reset_watermark:
        if window is not None or args.loop:
            raise SystemExit("--reset-watermark cannot be combined with replay bounds or --loop")
        reset_watermark(by_name[args.reset_watermark])
        return 0

    selected = [by_name[n.strip()] for n in args.tables.split(",")] if args.tables else list(TABLES)
    if window is not None and not args.tables:
        raise SystemExit("bounded replay requires an explicit --tables list")
    if window is not None and args.loop:
        raise SystemExit("bounded replay is one-shot and cannot be combined with --loop")

    if not args.loop:
        run_once(selected, window)
        return 0

    log.info("micro-batch loop every %ds over %d tables (Ctrl+C to stop)", args.loop, len(selected))
    while True:
        tick = time.monotonic()
        try:
            run_once(selected)
        except Exception as exc:  # noqa: BLE001 - connection level failures; keep the loop alive
            log.exception("batch failed at connection level: %s", exc)
        sleep_for = max(0.0, args.loop - (time.monotonic() - tick))
        log.info("sleeping %.0fs", sleep_for)
        try:
            time.sleep(sleep_for)
        except KeyboardInterrupt:
            log.info("stopped")
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
