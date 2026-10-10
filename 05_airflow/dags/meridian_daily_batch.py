# airflow DAG
"""
meridian_daily_batch  -  02:00 UTC

    extract slow/reference tables -> dbt snapshot -> dbt build daily -> reconcile -> docs

Why a separate daily DAG when the 5-minute one exists?
  * SCD2 snapshots and dimension rebuilds are not "hot path" work. Running them every 5 minutes
    would multiply versions (see snap_accounts 'check' strategy note) and cost credits for nothing.
  * The periodic snapshot fact is by definition a once-a-period calculation.
  * A full `dbt build` including every test is the daily quality gate; the micro-batch runs only
    the tests attached to hot-path models.
"""
from __future__ import annotations

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


@dag(
    dag_id="meridian_daily_batch",
    description="Snapshots, SCD2 dimensions, periodic/accumulating snapshot facts, full tests, docs",
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

    @task.bash
    def reconcile() -> str:
        return f"python {RECONCILE_SCRIPT} --days 7 --by currency --record"

    daily_extracts = extract_daily.expand(table=DAILY_TABLES)
    daily_extracts >> dbt_snapshot() >> dbt_build_daily() >> reconcile() >> dbt_docs() >> dbt_save_prod_manifest()


meridian_daily_batch()
