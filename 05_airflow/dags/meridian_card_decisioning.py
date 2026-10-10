"""
Weekly decisioning: refresh features, train from the gold layer, rebuild the card marts.

Airflow does not train inside a task body. It shells out to the same script you can
run from a laptop, then to the same dbt project. Scores land in MERIDIAN_RAW.ML;
nothing is written back to Postgres.
"""
from __future__ import annotations

import os

from _common import DEFAULT_ARGS, START_DATE, dag, dbt, task

DECISIONING_DIR = os.getenv("DECISIONING_DIR", "/usr/local/airflow/include/decisioning")


@dag(
    dag_id="meridian_card_decisioning",
    description="Train card models on gold features, publish scores, rebuild offer and application marts",
    schedule="0 3 * * 1",
    start_date=START_DATE,
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["meridian", "cards", "ml"],
)
def meridian_card_decisioning():

    @task.bash
    def refresh_features() -> str:
        return dbt("build -s +ml_customer_features fct_card_applications fct_card_authorizations")

    @task.bash
    def train_and_score() -> str:
        return f"cd {DECISIONING_DIR} && python train_and_score.py"

    @task.bash
    def build_scored_marts() -> str:
        return dbt("build -s stg_ml__model_scores+")

    refresh_features() >> train_and_score() >> build_scored_marts()


meridian_card_decisioning()
