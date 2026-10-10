# Python foundations for the Meridian pipeline

This is a short bridge into the project, not a separate Python course. Run the files in
number order. They use only Python's standard library, so they work before the full
project dependencies are installed.

## Where to run Python

- **Quick browser practice:** use the Python editor at
  [Programiz](https://www.programiz.com/python-programming/online-compiler/) or step
  through a tiny program at [Python Tutor](https://pythontutor.com/).
- **The real Meridian project:** use Python 3.12 in a local virtual environment. Browser
  editors cannot reach your Docker Postgres, read your private key, or load your
  Snowflake account.

```bash
cd /path/to/snowflake_dbt_airflow_python_byFK
python3 -m venv .venv
source .venv/bin/activate
python 02_ingestion_python/00_python_foundations/01_values_and_decisions.py
python 02_ingestion_python/00_python_foundations/02_loops_and_functions.py
python 02_ingestion_python/00_python_foundations/03_collections_paths_libraries.py
python 02_ingestion_python/00_python_foundations/04_mini_reconciliation.py
```

## What each file prepares you for

| Foundation | Where it appears in Meridian |
|---|---|
| `print`, variables, types and casting | environment variables become row limits, ports and thresholds |
| `if / elif / else` | choose a load mode; pass or fail a quality gate |
| `for` and `while` | process tables; repeat a five-minute micro-batch |
| functions and `return` | keep extraction, loading and validation separate |
| lists and dictionaries | hold table settings, rows and alert payloads |
| imports and libraries | pandas, pyarrow, Postgres and Snowflake connectors |
| exceptions | fail safely, close connections and leave the watermark unchanged |
| `Path` | find `.env`, Parquet files and the private key without fragile strings |
| command-line arguments | `--tables`, `--loop`, `--since` and `--until` |
| reconciliation | compare source and warehouse totals and show every mismatch |

After these four files, install the project libraries:

```bash
pip install -r requirements.txt pytest
python -c "import pandas, pyarrow, psycopg2, snowflake.connector; print('libraries ready')"
pytest -q tests
```

The next file to read is `02_ingestion_python/config.py`. Treat a `dataclass` as a named
bundle of settings and type hints as labels for readers. Then open
`pg_to_snowflake.py`; follow `main()` first instead of reading every line at once.
