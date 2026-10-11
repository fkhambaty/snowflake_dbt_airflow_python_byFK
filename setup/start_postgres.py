#!/usr/bin/env python3
"""Start and build the Meridian PostgreSQL source with the course SQL files."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "01_source_postgres"
COMPOSE_FILE = SOURCE / "docker-compose.postgres.yml"
CONTAINER = "meridian_postgres"
DATABASE = "meridian_core"
SQL_ORDER = (
    "01_ddl_core_schema.sql",
    "02_seed_reference_data.sql",
    "03_seed_bulk_data.sql",
    "07_ddl_cards.sql",
    "04_cdc_triggers.sql",
    "05_dml_simulator_functions.sql",
    "08_seed_cards.sql",
    "09_card_simulator.sql",
)


def run(
    command: list[str],
    *,
    check: bool = True,
    capture: bool = False,
    stdin=None,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=check,
        stdin=stdin,
        capture_output=capture,
        text=stdin is None,
    )


def docker(*arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    return run(["docker", *arguments], check=check)


def compose(*arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    return run(
        ["docker", "compose", "-f", str(COMPOSE_FILE), *arguments],
        check=check,
    )


def psql(database: str, *arguments: str, capture: bool = False, stdin=None):
    return run(
        [
            "docker",
            "exec",
            "-i",
            CONTAINER,
            "psql",
            "-X",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            "meridian",
            "-d",
            database,
            *arguments,
        ],
        capture=capture,
        stdin=stdin,
    )


def query(database: str, sql: str) -> str:
    result = psql(database, "-tAc", sql, capture=True)
    return result.stdout.strip()


def wait_for_postgres(timeout_seconds: int = 120) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        result = docker(
            "exec",
            CONTAINER,
            "pg_isready",
            "-U",
            "meridian",
            "-d",
            "postgres",
            check=False,
        )
        if result.returncode == 0:
            return
        time.sleep(2)
    raise RuntimeError(
        "PostgreSQL did not become ready within two minutes. "
        "Run: docker compose -f 01_source_postgres/docker-compose.postgres.yml logs postgres"
    )


def ensure_database() -> None:
    exists = query(
        "postgres",
        f"select 1 from pg_database where datname = '{DATABASE}'",
    )
    if exists == "1":
        print(f"Database already exists: {DATABASE}")
        return
    print(f"Creating database: {DATABASE}")
    psql("postgres", "-c", f"create database {DATABASE}")
    psql(
        "postgres",
        "-c",
        "comment on database meridian_core is "
        "'Meridian Bank core banking OLTP system (teaching replica)'",
    )


def table_exists(table: str) -> bool:
    return query(DATABASE, f"select to_regclass('{table}') is not null") == "t"


def completed_build() -> bool:
    if not table_exists("core.transactions"):
        return False
    transaction_count = int(query(DATABASE, "select count(*) from core.transactions"))
    return (
        transaction_count >= 5_000_000
        and table_exists("core.card_authorizations")
        and query(
            DATABASE,
            "select count(*) from pg_proc where proname = 'sim_tick'",
        )
        != "0"
    )


def partial_build() -> bool:
    return table_exists("core.transactions") and not completed_build()


def execute_sql_file(path: Path) -> None:
    print(f"\nExecuting {path.name} ...", flush=True)
    with path.open("rb") as sql:
        psql(DATABASE, "-f", "-", stdin=sql)
    print(f"Completed {path.name}", flush=True)


def print_counts() -> None:
    print("\nFinal source counts:")
    psql(
        DATABASE,
        "-c",
        """
        select 'branches' as object, count(*) from core.branches
        union all select 'customers', count(*) from core.customers
        union all select 'accounts', count(*) from core.accounts
        union all select 'transactions', count(*) from core.transactions
        union all select 'card_authorizations', count(*) from core.card_authorizations
        order by 1;
        """,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="delete the course Postgres volume and rebuild all source data",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    if not shutil.which("docker"):
        print("Docker was not found. Run the operating-system installer in setup/ first.")
        return 1
    if docker("info", check=False).returncode != 0:
        print("Docker Desktop is not running. Start it, wait for the engine, and retry.")
        return 1

    if args.rebuild:
        print("Removing only the Meridian course container and its named data volume...")
        compose("down", "--volumes", "--remove-orphans")

    print("Starting PostgreSQL 16...")
    compose("up", "-d")
    wait_for_postgres()
    ensure_database()

    if completed_build():
        print("The completed Meridian source already exists; no data was replaced.")
        print_counts()
        return 0

    if partial_build() and not args.rebuild:
        print(
            "\nA partial source build exists. To avoid mixing incomplete seed data, run:\n"
            f"  {sys.executable} setup/start_postgres.py --rebuild"
        )
        return 1

    for filename in SQL_ORDER:
        execute_sql_file(SOURCE / filename)

    if not completed_build():
        print("The scripts finished, but the final verification did not pass.")
        return 1

    print_counts()
    print("\nPostgreSQL is ready.")
    print("Open DBeaver and use the connection values in setup/README.md.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
