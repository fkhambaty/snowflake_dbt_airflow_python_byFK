# Snowflake, dbt, Airflow, and Python by FK

The runnable code for the Meridian Bank series. Clone this repository and follow the folders in number order. You do not need to copy code out of the video.

Meridian is a fictional bank: 520 branches, 5 currencies, retail accounts, and credit cards. The path is PostgreSQL → Python → Parquet → Snowflake → dbt → Airflow.

## What each folder is

| Folder | What you run |
|---|---|
| `setup/` | macOS/Windows installers, setup verifier, and the checked PostgreSQL build. Start here. |
| `01_source_postgres/` | The bank database SQL. The setup script executes it in the required order. |
| `02_ingestion_python/` | Four beginner Python lessons, then the extractor, Parquet loading, simulation, and reconciliation. |
| `03_snowflake/` | Warehouses, roles, raw tables, row access, and masking. Run in Snowsight. |
| `04_dbt_meridian_dw/` | Staging, the star schema, tests, and the public marts. |
| `05_airflow/` | The 5-minute load, the daily batch, and the freshness check. |
| `06_performance_lab/` | Queries that are slow on purpose, then the fix, with the numbers. |
| `07_data_modelling/` | The bus matrix and the diagrams the models follow. |
| `08_ci_cd/` | What the GitHub checks are for. The checks themselves are in `.github/workflows/`. |
| `09_decisioning_python/` | Train the card model from the gold features and write the scores back. |
| `10_semantic_app/` | Ask the warehouse a question in English. Row access still applies. |
| `11_platform_terraform/` | The same Snowflake roles and warehouses as code. |
| `tests/` | Python checks that run with no warehouse. |

## Run it

```bash
git clone https://github.com/fkhambaty/snowflake_dbt_airflow_python_byFK.git
cd snowflake_dbt_airflow_python_byFK
```

Follow [`setup/README.md`](setup/README.md). The short path is:

```bash
# macOS
bash setup/install_macos.sh

# Windows Administrator PowerShell
.\setup\install_windows.ps1

# Open Docker Desktop, wait for its engine, then verify and build the source.
python3 setup/verify_setup.py
python3 setup/start_postgres.py
```

On Windows, use `py -3.12` instead of `python3`.

The source script starts PostgreSQL 16, creates `meridian_core`, executes all source SQL
in the checked order, loads five million transactions, installs the simulators, and
prints the final counts. DBeaver connects to `localhost:5432`, database
`meridian_core`, username `meridian`, password `meridian`.

## Python lessons and tests

```bash

python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt pytest

# New to Python? Run these before the real pipeline.
python 02_ingestion_python/00_python_foundations/01_values_and_decisions.py
python 02_ingestion_python/00_python_foundations/02_loops_and_functions.py
python 02_ingestion_python/00_python_foundations/03_collections_paths_libraries.py
# This one deliberately exits 1 to demonstrate a failed quality gate.
python 02_ingestion_python/00_python_foundations/04_mini_reconciliation.py || true

pytest -q tests
```

Snowflake. In Snowsight, as ACCOUNTADMIN, run `03_snowflake/01`, then `02`, then `03`. Run the later scripts in that folder in numeric order when the lesson reaches them. `11_platform_terraform/` builds the same platform objects if you prefer Terraform.

Load.

```bash
cp .env.example .env
# Fill in your Snowflake account and key. Do not commit .env.
python3 02_ingestion_python/pg_to_snowflake.py
```

dbt, then the model.

```bash
cd 04_dbt_meridian_dw
cp profiles.yml.example profiles.yml
dbt deps && dbt build --target prod
```

In Snowsight, as ACCOUNTADMIN, execute `03_snowflake/06_row_level_security.sql`. Then:

```bash
dbt run-operation apply_governance_all --target prod
cd ..
python3 09_decisioning_python/train_and_score.py
cd 04_dbt_meridian_dw && dbt build -s stg_ml__model_scores+ --target prod
```

`.env`, `profiles.yml`, and the private key stay on your machine. `.env.example` and `profiles.yml.example` show the names of the settings and contain no account secrets.
