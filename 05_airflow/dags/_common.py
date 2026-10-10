"""
Shared bits for the Meridian DAGs.

Airflow 3 exposes the public authoring API under `airflow.sdk`; Airflow 2.9+ still uses
`airflow.decorators`. The try/except keeps the same DAG files working on both (documented
exception to the "no fallback imports" rule).
"""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

try:
    from airflow.sdk import Param, dag, task  # Airflow 3
except ImportError:  # pragma: no cover - Airflow 2 fallback
    from airflow.decorators import dag, task  # type: ignore[no-redef]
    from airflow.models.param import Param  # type: ignore[no-redef]

from meridian_alerts import send_alert

DBT_PROJECT_DIR = os.getenv("DBT_PROJECT_DIR", "/usr/local/airflow/include/dbt")
INGEST_DIR = os.getenv("INGEST_DIR", "/usr/local/airflow/include/ingestion")
DBT_TARGET = os.getenv("DBT_TARGET", "prod")
INGEST_POOL = os.getenv("AIRFLOW_INGEST_POOL", "meridian_postgres")
MAX_PIPELINE_LAG_MINUTES = int(os.getenv("MAX_PIPELINE_LAG_MINUTES", "15"))

START_DATE = datetime(2026, 1, 1, tzinfo=timezone.utc)


def log_failure(context: dict) -> None:
    """Runs once a task has used up its retries: one JSON log line, plus Slack when a webhook is set."""
    task_instance = context.get("task_instance")
    payload = {
        "event": "meridian_task_failed",
        "dag_id": getattr(task_instance, "dag_id", None),
        "task_id": getattr(task_instance, "task_id", None),
        "run_id": context.get("run_id"),
        "try_number": getattr(task_instance, "try_number", None),
        "log_url": getattr(task_instance, "log_url", None),
        "exception": str(context.get("exception", ""))[:1000],
    }
    send_alert(payload)


DEFAULT_ARGS = {
    "owner": "fk",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
    "retry_exponential_backoff": True,
    "execution_timeout": timedelta(minutes=20),
    "on_failure_callback": log_failure,
}

HOT_TABLES = [
    "core.transactions",
    "core.card_applications",
    "core.card_authorizations",
    "cdc.deleted_records",
]

# Reference and slow-changing master data do not justify 288 extraction attempts per day.
# The daily DAG refreshes these before snapshots and dimensions.
DAILY_TABLES = [
    "ref.currencies", "ref.countries", "ref.channels", "ref.products", "ref.fx_rates",
    "ref.merchants", "ref.sale_events", "ref.offer_catalog",
    "core.branches", "core.employees", "core.customers", "core.accounts", "core.account_holders",
    "core.loan_applications",
    "core.customer_features", "core.card_applications", "core.credit_cards",
]
SOURCE_TABLES = HOT_TABLES + [table for table in DAILY_TABLES if table not in HOT_TABLES]


def dbt(cmd: str) -> str:
    """Build a dbt shell command that runs inside the project directory with the right target."""
    return f"cd {DBT_PROJECT_DIR} && dbt {cmd} --target {DBT_TARGET} --no-use-colors"


__all__ = [
    "dag", "task", "Param", "dbt", "DEFAULT_ARGS", "START_DATE", "SOURCE_TABLES",
    "HOT_TABLES", "DAILY_TABLES", "INGEST_POOL", "MAX_PIPELINE_LAG_MINUTES",
    "INGEST_DIR", "DBT_PROJECT_DIR",
]
