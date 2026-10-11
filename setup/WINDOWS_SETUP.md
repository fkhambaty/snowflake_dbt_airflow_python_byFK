# Windows 10/11 setup for the Meridian course

Use this page on Windows. Run the commands in **Windows PowerShell**, not inside a
WSL terminal.

## What this course uses

The setup is deliberately split so you install each tool only when it becomes useful.

### Installed now

- **Git** — downloads and versions the project.
- **Cursor** — opens and edits SQL, Python, YAML and Terraform files.
- **Python 3.12** — runs the loader, reconciliation, tests and data app.
- **Docker Desktop + Docker Compose** — runs the local containers through WSL 2.
- **DBeaver Community** — lets you inspect and query the local source.
- **Terraform** — builds the Snowflake platform from code later in the course.

### Installed inside the project

`py -3.12 -m pip install -r requirements.txt` installs **dbt Core**,
**dbt-snowflake**, pandas, PyArrow, the Snowflake connector, Streamlit,
scikit-learn and the other Python libraries used by the project.

### Installed later

- **Astro CLI** — runs Apache Airflow locally. Install it in the Airflow episode.

### Used in a browser; not installed

- **GitHub** — hosts the code and runs the checks.
- **Snowflake Snowsight** — the Snowflake web interface. You create an account in
  the Snowflake episode.

## 1. Get the code

If Git is already installed, open PowerShell and run:

```powershell
git clone https://github.com/fkhambaty/snowflake_dbt_airflow_python_byFK.git
cd snowflake_dbt_airflow_python_byFK
```

If Git is not installed, download the repository ZIP from GitHub and extract it.
Open the extracted folder in File Explorer, right-click an empty area, and choose
**Open in Terminal**.

## 2. Install the desktop and command-line tools

Open **PowerShell as Administrator** in the repository folder:

```powershell
wsl --update
wsl --install --no-distribution
Set-ExecutionPolicy -Scope Process Bypass
.\setup\install_windows.ps1
```

The first two commands prepare the WSL 2 engine used by Docker. Restart Windows if
they request it, reopen Administrator PowerShell in the repository folder, and then
run the final two commands. The script uses `winget`. If `winget` is unavailable,
install or update **App Installer** from Microsoft Store and run the script again.

When the script finishes:

1. Restart Windows if Docker Desktop asks you to.
2. Open **Docker Desktop**.
3. Use the WSL 2 engine when prompted.
4. Wait until Docker says its engine is running.
5. Open a new Windows PowerShell window in the repository folder.

## 3. Verify the machine

```powershell
py -3.12 setup\verify_setup.py
```

Every required row must say `PASS`. PostgreSQL may say `INFO` until the next step
creates its container.

## 4. Install the project libraries

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt pytest
dbt --version
```

If PowerShell blocks activation, allow scripts only for this PowerShell window:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\.venv\Scripts\Activate.ps1
```

The prompt normally starts with `(.venv)` after activation. Activate it again
whenever you open a new PowerShell window for this project.

## 5. Build the local source

```powershell
py -3.12 setup\start_postgres.py
```

The script owns the SQL file order and prints the final row counts. Do not close
PowerShell while `03_seed_bulk_data.sql` is running.

## 6. Install Airflow only when the course reaches it

Astro CLI runs directly in Windows PowerShell. The project already uses Docker, so
skip Astro's additional Podman dependency:

```powershell
winget install -e --id Astronomer.Astro --skip-dependencies
astro version
```

Restart Windows if WSL requests it, then follow `05_airflow/README.md`.

## If a command says a file does not exist

Check your current folder:

```powershell
Get-Location
```

It must end in `snowflake_dbt_airflow_python_byFK`. If it does not:

```powershell
cd C:\path\to\snowflake_dbt_airflow_python_byFK
```
