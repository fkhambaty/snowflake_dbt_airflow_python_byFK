# airflow DAG
"""
meridian_source_freshness  -  every 15 minutes

A watchdog DAG. `dbt source freshness` compares max(_extracted_at) in raw with now() against the
SLAs declared in _postgres__sources.yml. Exit code != 0 -> task fails -> alert.
Keeping it separate from the ingest DAG means a dead ingestion loop is still detected.
"""
from __future__ import annotations

from _common import DEFAULT_ARGS, START_DATE, dag, dbt, task


@dag(
    dag_id="meridian_source_freshness",
    description="Raw layer freshness SLA check",
    schedule="*/15 * * * *",
    start_date=START_DATE,
    catchup=False,
    max_active_runs=1,
    default_args={**DEFAULT_ARGS, "retries": 0},
    tags=["meridian", "observability"],
)
def meridian_source_freshness():

    @task.bash
    def dbt_source_freshness() -> str:
        return dbt("source freshness")

    dbt_source_freshness()


meridian_source_freshness()
