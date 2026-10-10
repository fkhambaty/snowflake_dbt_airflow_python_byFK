"""
meridian_microbatch_ingest  -  every 5 minutes

    [extract_load x 4 hot tables, dynamically mapped]  ->  dbt build --selector microbatch

Design notes (Episode 7):
  * max_active_runs=1 : a slow batch must never overlap with the next one (watermarks would race).
  * catchup=False     : the watermark already encodes "where we are"; replaying old intervals is meaningless.
  * Dynamic task mapping gives one task instance per table -> per-table retries and logs,
    and the small tables do not wait for transactions.
  * The task only shells out to pg_to_snowflake.py. Airflow schedules; it does not transform.
  * A dbt failure here does NOT roll back the raw load: raw is append-only and the next dbt run
    simply picks up where the watermark on _extracted_at left off. Idempotency by design.
"""
from __future__ import annotations

from _common import (
    DEFAULT_ARGS,
    HOT_TABLES,
    INGEST_DIR,
    INGEST_POOL,
    MAX_PIPELINE_LAG_MINUTES,
    START_DATE,
    dag,
    dbt,
    task,
)


@dag(
    dag_id="meridian_microbatch_ingest",
    description="Postgres -> Snowflake raw -> dbt hot path, every 5 minutes",
    schedule="*/5 * * * *",
    start_date=START_DATE,
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["meridian", "ingestion", "microbatch"],
)
def meridian_microbatch_ingest():

    @task.bash(pool=INGEST_POOL, max_active_tis_per_dag=4)
    def extract_load(table: str) -> str:
        return f"cd {INGEST_DIR} && python pg_to_snowflake.py --tables {table}"

    @task.bash
    def dbt_build_hot_path() -> str:
        # staging + intermediate views, incremental fct_transactions, 2-day aggregate refresh, their tests
        return dbt("build --selector microbatch")

    @task.bash(trigger_rule="all_done")
    def report_pipeline_health() -> str:
        # This is an SLO gate, not a decorative report. It fails if a hot table is stale
        # or its latest load failed. The separate freshness DAG catches a dead scheduler.
        return dbt(
            "run-operation assert_pipeline_health "
            f"--args '{{max_minutes: {MAX_PIPELINE_LAG_MINUTES}}}'"
        )

    extract_load.expand(table=HOT_TABLES) >> dbt_build_hot_path() >> report_pipeline_health()


meridian_microbatch_ingest()
