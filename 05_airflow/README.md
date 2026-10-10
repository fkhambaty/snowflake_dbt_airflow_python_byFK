# Airflow (Astro CLI) for Meridian Bank

Astro CLI is the fastest way to run a clean Airflow 3 locally with Docker:

```bash
brew install astro                      # https://www.astronomer.io/docs/astro/cli/install-cli
cd 05_airflow
mkdir -p .astro
test -f .astro/config.yaml || printf 'project:\n    name: meridian\n' > .astro/config.yaml
cp ../.env .env                         # Postgres + Snowflake credentials -> Airflow containers
mkdir -p include && cp -R ../04_dbt_meridian_dw include/dbt && cp -R ../02_ingestion_python include/ingestion && cp -R ../09_decisioning_python include/decisioning
cp airflow_settings.yaml.example airflow_settings.yaml
astro dev start
astro dev object import                 # creates the four-slot ingestion pool
```

Postgres runs on the host, so inside the containers `PG_HOST=host.docker.internal`.

| DAG | Schedule | What it does |
|---|---|---|
| `meridian_microbatch_ingest` | every 5 min | maps over four hot/CDC tables in a four-slot pool, builds the hot selector, then enforces the 15-minute health threshold |
| `meridian_daily_batch` | 02:00 UTC | extracts slow/reference tables, snapshots and builds, records reconciliation, refreshes reference search ids, and uploads the production manifest to Snowflake's internal artifact stage |
| `meridian_source_freshness` | every 15 min | `dbt source freshness` → fails loudly if raw is stale |
| `meridian_card_decisioning` | Mondays 03:00 UTC | `dbt build` the feature marts → train and score from gold (writes `MERIDIAN_RAW.ML`; a model below the AUC gate is not published) → `dbt build -s stg_ml__model_scores+` |
| `meridian_bounded_replay` | manual only | validates timezone-aware start/end and selected tables, replays that immutable window without advancing watermarks, then rebuilds the selected downstream path |

The **ingestion DAG re-uses `pg_to_snowflake.py` unchanged**: the DAG is only a scheduler and a
retry policy. That is the point of Airflow — it does not transform anything itself.
All tasks use a structured failure callback. Extraction errors propagate to Airflow; they
are not hidden with a successful shell exit. Use bounded replay for an incident instead of
resetting a global watermark.

Without Docker/Astro you can still demo the same thing with two terminals:
`python pg_to_snowflake.py --loop 300` and `watch -n 300 dbt build --selector microbatch`.
