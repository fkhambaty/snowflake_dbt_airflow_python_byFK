# macOS setup for the Meridian course

Use this page on a Mac. Run every command from the repository folder, not from `~`.

## What this course uses

The setup is deliberately split so you install each tool only when it becomes useful.

### Installed now

- **Git** — downloads and versions the project.
- **Visual Studio Code** — opens and edits SQL, Python, YAML and Terraform files.
- **Python 3.12** — runs the loader, reconciliation, tests and data app.
- **Docker Desktop + Docker Compose** — runs the local containers.
- **DBeaver Community** — lets you inspect and query the local source.
- **Terraform** — builds the Snowflake platform from code later in the course.

### Installed inside the project

`pip install -r requirements.txt` installs **dbt Core**, **dbt-snowflake**, pandas,
PyArrow, the Snowflake connector, Streamlit, scikit-learn and the other Python
libraries used by the project.

### Installed later

- **Astro CLI** — runs Apache Airflow locally. Install it in the Airflow episode.

### Used in a browser; not installed

- **GitHub** — hosts the code and runs the checks.
- **Snowflake Snowsight** — the Snowflake web interface. You create an account in
  the Snowflake episode.

## 1. Get the code

If Git is already installed:

```bash
git clone https://github.com/fkhambaty/snowflake_dbt_airflow_python_byFK.git
cd snowflake_dbt_airflow_python_byFK
```

If Git is not installed, download the repository ZIP from GitHub, extract it, open
the extracted folder in Finder, right-click the folder, and choose **New Terminal at
Folder**. Do not run the commands from a Terminal prompt that ends in `~`.

## 2. Install the desktop and command-line tools

From the repository folder:

```bash
bash setup/install_macos.sh
```

The script uses Homebrew. If Homebrew is missing, it asks before installing it.

When the script finishes:

1. Open **Docker Desktop** from Applications.
2. Accept its first-run prompts.
3. Wait until Docker says its engine is running.
4. Close Terminal and open a new Terminal in the repository folder.

## 3. Verify the machine

```bash
python3 setup/verify_setup.py
```

Every required row must say `PASS`. PostgreSQL may say `INFO` until the next step
creates its container.

## 4. Install the project libraries

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt pytest
dbt --version
```

The prompt normally starts with `(.venv)` after activation. Run
`source .venv/bin/activate` again whenever you open a new Terminal for this project.

## 5. Build the local source

```bash
python3 setup/start_postgres.py
```

The script owns the SQL file order and prints the final row counts. Do not close the
Terminal while `03_seed_bulk_data.sql` is running.

## 6. Install Airflow only when the course reaches it

The project already uses Docker, so install Astro without its additional Podman
dependency:

```bash
brew tap astronomer/tap
brew install astronomer/tap/astro --without-podman
astro version
```

Then follow `05_airflow/README.md`.

## If a command says a file does not exist

Check your current folder:

```bash
pwd
```

It must end in `snowflake_dbt_airflow_python_byFK`. If it does not:

```bash
cd /path/to/snowflake_dbt_airflow_python_byFK
```
