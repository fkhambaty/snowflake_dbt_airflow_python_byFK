"""Run the AcmeCloud customer-health case on labelled synthetic seeds.

DuckDB stands in for Snowflake so the SQL executes offline. The mart grain is
one row per Salesforce account per snapshot date. Rebuilding a snapshot date
replaces that partition and no other partition.
"""

from pathlib import Path

import duckdb

CASE_DIR = Path(__file__).resolve().parent
SEEDS_DIR = CASE_DIR / "seeds"
SQL_DIR = CASE_DIR / "sql"

BUSINESS_TIMEZONE = "America/New_York"
HEALTH_SCORE_VERSION = "v1"
FX_POLICY = "fx_policy_v1_latest_rate_on_or_before_period_start"

SEED_TABLES = (
    "salesforce_accounts",
    "salesforce_renewals",
    "stripe_subscriptions",
    "stripe_invoices",
    "stripe_payments",
    "fx_rates",
    "product_users",
    "product_events",
    "product_entitlements",
    "zendesk_tickets",
    "zendesk_csat",
    "account_crosswalk",
    "source_extracts",
    "churn_outcomes",
)

SQL_FILES = (
    "00_control.sql",
    "10_staging.sql",
    "20_intermediate.sql",
    "30_snapshot.sql",
    "40_quality.sql",
)

DEFAULT_SNAPSHOTS = (
    ("2026-09-01", "2026-09-02 06:00:00"),
    ("2026-10-01", "2026-10-02 06:00:00"),
)


def connect() -> duckdb.DuckDBPyConnection:
    """Load seeds and compile the warehouse views in a private DuckDB database."""
    connection = duckdb.connect(database=":memory:")
    connection.execute("SET TimeZone = 'UTC'")
    _load_seeds(connection)
    for filename in SQL_FILES[:3]:
        _execute_sql_file(connection, filename)
    set_run(connection, "1900-01-01", "1900-01-01 00:00:00")
    for filename in SQL_FILES[3:]:
        _execute_sql_file(connection, filename)
    connection.execute("DELETE FROM pipeline_run")
    connection.execute("DELETE FROM fct_account_health_daily")
    return connection


def set_run(connection: duckdb.DuckDBPyConnection, snapshot_date: str, as_of_timestamp: str) -> None:
    """Point the current-run views at one snapshot cutoff."""
    connection.execute("DELETE FROM pipeline_run")
    connection.execute(
        """
        INSERT INTO pipeline_run
        SELECT CAST(? AS DATE), CAST(? AS TIMESTAMP), ?, ?
        """,
        [snapshot_date, as_of_timestamp, BUSINESS_TIMEZONE, HEALTH_SCORE_VERSION],
    )


def build_snapshot(connection: duckdb.DuckDBPyConnection, snapshot_date: str, as_of_timestamp: str) -> None:
    """Idempotently replace one daily account-health partition."""
    set_run(connection, snapshot_date, as_of_timestamp)
    connection.execute(
        "DELETE FROM fct_account_health_daily WHERE snapshot_date = CAST(? AS DATE)",
        [snapshot_date],
    )
    connection.execute(
        "INSERT INTO fct_account_health_daily SELECT * FROM int_account_health_snapshot"
    )


def build_default(connection: duckdb.DuckDBPyConnection) -> None:
    """Build the September and October snapshots used by the case tests."""
    for snapshot_date, as_of_timestamp in DEFAULT_SNAPSHOTS:
        build_snapshot(connection, snapshot_date, as_of_timestamp)


def fetch_dicts(connection: duckdb.DuckDBPyConnection, sql: str, params: list | None = None) -> list[dict]:
    """Return query rows as dictionaries keyed by column name."""
    result = connection.execute(sql, params or [])
    columns = [item[0] for item in result.description]
    return [dict(zip(columns, row)) for row in result.fetchall()]


def main() -> None:
    """Print the published mart after the default snapshot build."""
    connection = connect()
    build_default(connection)
    rows = fetch_dicts(
        connection,
        """
        SELECT
            snapshot_date,
            salesforce_account_id,
            account_name,
            mrr_usd,
            health_score,
            risk_band,
            priority_score,
            publish_status
        FROM mart_customer_success_health
        ORDER BY snapshot_date, priority_score DESC, salesforce_account_id
        """,
    )
    for row in rows:
        print(
            f"{row['snapshot_date']} {row['salesforce_account_id']} "
            f"mrr={row['mrr_usd']} health={row['health_score']} "
            f"risk={row['risk_band']} priority={row['priority_score']} "
            f"publish={row['publish_status']}"
        )


def _load_seeds(connection: duckdb.DuckDBPyConnection) -> None:
    for table_name in SEED_TABLES:
        path = SEEDS_DIR / f"{table_name}.csv"
        if not path.is_file():
            raise FileNotFoundError(f"Missing synthetic seed: {path}")
        connection.execute(
            f"""
            CREATE TABLE raw_{table_name} AS
            SELECT *
            FROM read_csv(?, header = true, nullstr = '', sample_size = -1)
            """,
            [str(path)],
        )


def _execute_sql_file(connection: duckdb.DuckDBPyConnection, filename: str) -> None:
    connection.execute((SQL_DIR / filename).read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
