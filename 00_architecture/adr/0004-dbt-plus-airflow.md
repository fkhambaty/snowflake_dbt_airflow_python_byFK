# 0004. dbt for transformation, Airflow for orchestration

**Status:** Accepted

## Context
There are 50 models with tests, a 5-minute hot path, a daily batch, and a Python training
job that must run between two dbt builds.

## Decision
dbt owns every SQL transformation, test, contract and data grant. Airflow only schedules:
it calls the extractor, `dbt build --selector ...`, and the training script. No SQL
lives in DAG files.

## Alternatives
| Option | Why not (here) |
|---|---|
| Snowflake Dynamic Tables | Excellent for declarative freshness (`TARGET_LAG`) inside Snowflake. They cannot run the Python extractor in Postgres or the training job. Testing and CI are weaker than dbt's. **Good fit for the fraud path later.** |
| Snowflake Tasks + streams | Shown in `03_snowflake/04` for teaching. Orchestration logic scattered in SQL is hard to review and test. |
| Astronomer Cosmos (one Airflow task per dbt model) | Better per-model retries and visibility, at the cost of hundreds of tasks and slower DAG parsing. Removed from the course because it duplicated the daily DAG. `dbt build` with selectors is enough at 50 models. |
| dbt Cloud scheduler | Fine for dbt alone. It still needs an orchestrator for extract and training. |

## Consequences
* One place to read transformation logic, and one CI pipeline for it.
* Model-level failure visibility lives in dbt artifacts (`run_results.json`), not in the Airflow grid.

## Revisit when
The model count passes about 300, or per-model SLAs appear. Then evaluate Cosmos, or
Dynamic Tables for the hot path.
