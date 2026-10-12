# Snowflake, dbt, Airflow, and Python by FK

The runnable Meridian Bank project. Clone this repository, open the study guide, then follow the folders in number order.

Meridian is a fictional bank: 520 branches, five currencies, retail accounts, and credit cards. The path is PostgreSQL, then Python and Parquet, then Snowflake, dbt, and Airflow. Scores, a plain-English app, and platform-as-code sit on the same warehouse.

## Study before you press play

Open [`study/index.html`](study/index.html) in a browser. It is a self-contained pre-video guide: episode order E0, E1, E2, E3, P0, then E4 through E13, the exact files and commands, expected results, failure modes, exercises, and the interview defenses. It does not need a network connection.

[`study/coverage.json`](study/coverage.json) maps every episode and interview topic to files and anchors in that page. [`study/README.md`](study/README.md) is the short operating note.

Read [`00_architecture/DESIGN_DOC.md`](00_architecture/DESIGN_DOC.md) before the first Snowflake worksheet. The decision records are in [`00_architecture/adr/`](00_architecture/adr/).

## What each folder is

| Folder | What you run |
|---|---|
| `study/` | The pre-video guide. Open `index.html`. |
| `00_architecture/` | Design doc, architecture process, runbooks, and decision records. |
| `setup/` | macOS and Windows installers, the setup verifier, and the checked PostgreSQL build. Start here when you are ready to run. |
| `01_source_postgres/` | The bank database SQL. The setup script executes the build files in the required order. |
| `02_ingestion_python/` | Four beginner Python lessons, then the extractor, Parquet loading, simulation, and reconciliation. |
| `03_snowflake/` | Warehouses, roles, raw tables, row access, masking, search, cost, clone, and recovery. Run in Snowsight. |
| `04_dbt_meridian_dw/` | Staging, the star schema, tests, and the public marts. |
| `05_airflow/` | The 5-minute load, the daily batch, freshness, replay, and card decisioning. |
| `06_performance_lab/` | Queries that are slow on purpose, then one measured fix. |
| `07_data_modelling/` | The bus matrix and the diagrams the models follow. |
| `.github/workflows/` | The checks that run when code changes. |
| `09_decisioning_python/` | Train the card models from the gold features and write the scores back. |
| `10_semantic_app/` | Ask the warehouse a question in English. Row access still applies. |
| `11_platform_terraform/` | The same Snowflake roles and warehouses as code. |
| `12_case_studies/` | The synthetic customer-health interview case. Run it with pytest. No warehouse is required. |
| `tests/` | Python checks that run with no warehouse. |

## Run it

```bash
git clone https://github.com/fkhambaty/snowflake_dbt_airflow_python_byFK.git
cd snowflake_dbt_airflow_python_byFK
```

Choose the instructions for your computer:

- [macOS setup](setup/MACOS_SETUP.md)
- [Windows 10/11 setup](setup/WINDOWS_SETUP.md)

[`setup/README.md`](setup/README.md) is the short cross-platform reference. The short path is:

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

The source script starts PostgreSQL 16, creates `meridian_core`, executes the source SQL in the checked order, loads five million transactions, installs the simulators, and prints the final counts. DBeaver connects to `localhost:5432`, database `meridian_core`, username `meridian`, password `meridian`.

## Python lessons and tests

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt pytest

python3 02_ingestion_python/00_python_foundations/01_values_and_decisions.py
python3 02_ingestion_python/00_python_foundations/02_loops_and_functions.py
python3 02_ingestion_python/00_python_foundations/03_collections_paths_libraries.py
# This lesson exits 1 on purpose. The mismatched INR group is the demonstration.
python3 02_ingestion_python/00_python_foundations/04_mini_reconciliation.py || true

pytest -q tests
```

Snowflake. In Snowsight, as ACCOUNTADMIN, run `03_snowflake/01`, then `02`, then `03`. Run the later scripts in that folder in numeric order when the lesson reaches them. `11_platform_terraform/` builds the same platform objects when you prefer Terraform.

Load.

```bash
cp .env.example .env
# Fill in your Snowflake account and key. Do not commit .env.
python3 02_ingestion_python/pg_to_snowflake.py
```

dbt, then governance, then the models.

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

Account-dependent Snowflake results in the study guide are labelled as expected results. A green offline test is evidence that the Python and the project parse. It is not evidence that a warehouse policy or a Cortex call ran in your account.
