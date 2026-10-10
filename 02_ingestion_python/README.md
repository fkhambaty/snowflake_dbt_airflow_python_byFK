# Python ingestion path

Read and run this folder in this order:

1. `00_python_foundations/` — four standard-library lessons covering values, decisions,
   loops, functions, collections, imports, paths, libraries, and a tiny reconciliation.
2. `config.py` — typed settings and the replicated-table registry.
3. `pg_to_snowflake.py` — watermark-driven Postgres extraction, Parquet files, Snowflake
   staging, `COPY INTO`, and safe watermark advancement.
4. `simulate_activity.py` — realistic source changes for repeated micro-batches.
5. `reconcile_with_pandas.py` — an independent source-to-warehouse balance check.
6. `dbt_artifact.py` — reads dbt artifacts for orchestration and observability.

Use Python 3.12 in a local virtual environment for the real pipeline. A browser
interpreter is useful only for the foundation syntax because it cannot access local
Postgres, Snowflake credentials, or project files.

## Reconciliation contract

The reconciliation process creates one UTC cutoff two minutes behind the current time
and applies it to both systems. It compares either date/currency or date/branch groups,
using exact row counts and the sum of `POSTED` local amounts. An outer merge keeps
source-only and warehouse-only groups visible. Every row count must match exactly and
every amount difference must be below one cent; otherwise the process exits with status
`1`. Pass `--record` to persist the result in
`MERIDIAN_RAW.CONTROL.RECONCILIATION_RUNS`.

This is intentionally separate from:

- **freshness**, which asks when data arrived;
- **dbt tests**, which check rules within Snowflake;
- **reconciliation**, which checks whether moving data changed business truth.
