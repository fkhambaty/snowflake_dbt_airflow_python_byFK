# Student setup: one path, checked at every step

These scripts prepare the local tools used by the course. They do not ask for, create,
or store Snowflake credentials.

## 1. Get this repository

Install Git, then run:

```bash
git clone https://github.com/fkhambaty/snowflake_dbt_airflow_python_byFK.git
cd snowflake_dbt_airflow_python_byFK
```

If Git is not installed yet, download the repository ZIP from GitHub, extract it, and
open Terminal or PowerShell inside the extracted folder.

## 2. Install the local tools

### macOS

The script uses Homebrew and installs Docker Desktop, DBeaver Community, Cursor,
Python 3.12, Git, and Terraform.

```bash
bash setup/install_macos.sh
```

When it finishes, open Docker Desktop once, accept its prompts, and wait until it says
the engine is running. Close and reopen Terminal so newly installed commands are on
`PATH`.

### Windows 10/11

Open **PowerShell as Administrator** in the repository folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup\install_windows.ps1
```

The script uses `winget` to install Docker Desktop, DBeaver Community, Cursor,
Python 3.12, Git, and Terraform. Restart Windows after Docker Desktop requests it.
Docker Desktop must be configured to use WSL 2.

### Linux

Install Docker Engine plus the Compose plugin from Docker's instructions for your
distribution, then install Python 3.12, Git, and DBeaver Community. The project scripts
after this point are operating-system independent.

## 3. Verify the machine

Run this from the repository root:

```bash
python3 setup/verify_setup.py
```

On Windows, if `python3` is not recognised:

```powershell
py -3.12 setup\verify_setup.py
```

Every required row must say `PASS`. Cursor is convenient but optional; any
VS Code-compatible editor can edit the files.

## 4. Build the PostgreSQL source automatically

Docker Desktop must already be running.

macOS/Linux:

```bash
python3 setup/start_postgres.py
```

Windows:

```powershell
py -3.12 setup\start_postgres.py
```

The script:

1. starts the PostgreSQL 16 container;
2. waits until PostgreSQL is ready;
3. creates `meridian_core` if it does not exist;
4. executes the course SQL files in the required order;
5. loads 520 branches, 200,000 customers and 5,000,000 transactions;
6. installs the CDC and activity simulators;
7. prints the final row counts.

The bulk seed takes several minutes. Do not stop the script while it says
`03_seed_bulk_data.sql`.

Running it again is safe: if the completed database already contains the expected
tables and rows, it verifies the existing build instead of reseeding it. To deliberately
erase the course database and rebuild it:

```bash
python3 setup/start_postgres.py --rebuild
```

## 5. Connect DBeaver

Create a PostgreSQL connection with exactly these values:

| Setting | Value |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `meridian_core` |
| Username | `meridian` |
| Password | `meridian` |

On the first connection, DBeaver may offer to download the PostgreSQL JDBC driver.
Click **Download**, then **Test Connection**, then expand:

`Databases → meridian_core → Schemas → core → Tables`

You should see tables including `customers`, `accounts`, and `transactions`.

## If something fails

Run:

```bash
python3 setup/verify_setup.py
docker compose -f 01_source_postgres/docker-compose.postgres.yml ps
docker compose -f 01_source_postgres/docker-compose.postgres.yml logs postgres
```

Do not continue to Snowflake until `verify_setup.py` passes and DBeaver can query:

```sql
select count(*) from core.transactions;
```
