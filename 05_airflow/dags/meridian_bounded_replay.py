"""
Manual, bounded replay. This is deliberately not Airflow catchup:
the source watermark defines normal progress, while this DAG re-lands one historical
window without changing that watermark. Append-only raw + staging dedupe make it safe.
"""
from __future__ import annotations

from _common import (
    DEFAULT_ARGS,
    INGEST_DIR,
    INGEST_POOL,
    Param,
    SOURCE_TABLES,
    START_DATE,
    dag,
    dbt,
    task,
)

ISO_PATTERN = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"


@dag(
    dag_id="meridian_bounded_replay",
    description="Re-land one source table for an explicit UTC window; normal watermark unchanged",
    schedule=None,
    start_date=START_DATE,
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    params={
        "table": Param("core.transactions", type="string", enum=SOURCE_TABLES),
        "since": Param("2026-09-01T00:00:00Z", type="string", pattern=ISO_PATTERN),
        "until": Param("2026-09-02T00:00:00Z", type="string", pattern=ISO_PATTERN),
        "dbt_selector": Param("microbatch", type="string", enum=["microbatch", "daily"]),
    },
    tags=["meridian", "backfill", "manual"],
)
def meridian_bounded_replay():

    @task.bash(
        pool=INGEST_POOL,
        env={
            "REPLAY_TABLE": "{{ params.table }}",
            "REPLAY_SINCE": "{{ params.since }}",
            "REPLAY_UNTIL": "{{ params.until }}",
        },
    )
    def extract_window() -> str:
        return (
            f"cd {INGEST_DIR} && python pg_to_snowflake.py "
            '--tables "$REPLAY_TABLE" --since "$REPLAY_SINCE" --until "$REPLAY_UNTIL"'
        )

    @task.bash(env={"DBT_SELECTOR": "{{ params.dbt_selector }}"})
    def rebuild_consumers() -> str:
        return dbt('build --selector "$DBT_SELECTOR"')

    extract_window() >> rebuild_consumers()


meridian_bounded_replay()
