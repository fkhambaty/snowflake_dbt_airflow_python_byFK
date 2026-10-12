# airflow DAG
"""
meridian_daily_batch  -  02:00 UTC

    extract slow/reference tables -> dbt snapshot -> dbt build daily
        -> mart integrity -> reconcile -> docs

Why a separate daily DAG when the 5-minute one exists?
  * SCD2 snapshots and dimension rebuilds are not "hot path" work. Running them every 5 minutes
    would multiply versions (see snap_accounts 'check' strategy note) and cost credits for nothing.
  * The periodic snapshot fact is by definition a once-a-period calculation.
  * A full `dbt build` including every test is the daily quality gate; the micro-batch runs only
    the tests attached to hot-path models.
  * Mart integrity runs after that build and before reconciliation. A violation fails this task,
    so reconcile does not publish a count against a corrupt mart.
"""
from __future__ import annotations

import os
import shlex
from pathlib import Path

from _common import (
    DAILY_TABLES,
    DBT_PROJECT_DIR,
    DEFAULT_ARGS,
    INGEST_DIR,
    INGEST_POOL,
    START_DATE,
    dag,
    dbt,
    task,
)

RECONCILE_SCRIPT = f"{INGEST_DIR}/reconcile_with_pandas.py"
_REPO_ROOT = Path(__file__).resolve().parents[2]
_REPO_INGEST = _REPO_ROOT / "02_ingestion_python"
_DEFAULT_INTEGRITY_SQL = _REPO_ROOT / "03_snowflake" / "11_mart_integrity_and_quarantine.sql"
INTEGRITY_SQL = os.getenv("MERIDIAN_INTEGRITY_SQL", str(_DEFAULT_INTEGRITY_SQL))

_INTEGRITY_PYTHON = """
import os
from io import StringIO
from pathlib import Path

from pg_to_snowflake import sf_connect
from snowflake.connector.util_text import split_statements

sql_path = Path(os.environ["MERIDIAN_INTEGRITY_SQL"])
sql = sql_path.read_text()
statements = []
for statement, _is_put in split_statements(StringIO(sql), remove_comments=False):
    kept_lines = []
    for line in statement.splitlines():
        if line.strip().startswith("--"):
            continue
        kept_lines.append(line)
    if "".join(kept_lines).strip().rstrip(";").strip():
        statements.append(statement)
if not statements:
    raise SystemExit("integrity SQL produced no statements")
connection = sf_connect(
    role="MERIDIAN_TRANSFORMER",
    warehouse="WH_TRANSFORM_XS",
    query_tag="meridian_mart_integrity",
)
connection.autocommit = True
try:
    cursor = connection.cursor()
    for statement in statements:
        cursor.execute(statement)
        if cursor.description is not None:
            cursor.fetchall()
finally:
    connection.close()
"""


@dag(
    dag_id="meridian_daily_batch",
    description="Snapshots, full dbt build, mart integrity, reconciliation, docs",
    schedule="0 2 * * *",
    start_date=START_DATE,
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["meridian", "dbt", "daily"],
)
def meridian_daily_batch():

    @task.bash(pool=INGEST_POOL, max_active_tis_per_dag=4)
    def extract_daily(table: str) -> str:
        return f"cd {INGEST_DIR} && python pg_to_snowflake.py --tables {table}"

    @task.bash
    def dbt_snapshot() -> str:
        return dbt("snapshot")

    @task.bash
    def dbt_build_daily() -> str:
        # dims, bridge, periodic + accumulating snapshot facts, aggregate, and ALL their tests
        # search_refresh_reference merges account and customer ids into omni_search.
        # The 5-minute DAG does not pass it, so those slow-changing ids are not re-merged all day.
        return dbt("build --selector daily --vars '{search_refresh_reference: true}'")

    @task.bash
    def dbt_docs() -> str:
        return dbt("docs generate --static")       # single-file docs: easy to upload to S3 / share on screen

    @task.bash
    def dbt_save_prod_manifest() -> str:
        # Snowflake is already the controlled platform. Keep the state artifact in its
        # internal stage instead of inventing an S3 dependency for one JSON file.
        return (
            f"python {INGEST_DIR}/dbt_artifact.py upload "
            f"{DBT_PROJECT_DIR}/target/manifest.json"
        )

    @task.bash(retries=0)
    def mart_integrity() -> str:
        # retries stay at 0: a duplicate key or an orphan is not a transient error.
        # The SQL raises after it has committed the exception row (key and reason).
        return "\n".join([
            "set -euo pipefail",
            f"INGEST_A={shlex.quote(INGEST_DIR)}",
            f"INGEST_B={shlex.quote(str(_REPO_INGEST))}",
            'if [ -f "$INGEST_A/pg_to_snowflake.py" ]; then INGEST="$INGEST_A"; else INGEST="$INGEST_B"; fi',
            'test -f "$INGEST/pg_to_snowflake.py"',
            'cd "$INGEST"',
            f"export MERIDIAN_INTEGRITY_SQL={shlex.quote(INTEGRITY_SQL)}",
            "python - <<'PY'",
            _INTEGRITY_PYTHON,
            "PY",
        ])

    @task.bash
    def reconcile() -> str:
        return f"python {RECONCILE_SCRIPT} --days 7 --by currency --record"

    daily_extracts = extract_daily.expand(table=DAILY_TABLES)
    snapshots = dbt_snapshot()
    built = dbt_build_daily()
    checked = mart_integrity()
    reconciled = reconcile()
    docs = dbt_docs()
    manifest = dbt_save_prod_manifest()
    daily_extracts >> snapshots >> built >> checked >> reconciled >> docs >> manifest


meridian_daily_batch()
