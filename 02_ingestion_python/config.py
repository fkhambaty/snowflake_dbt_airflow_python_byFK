"""
Central configuration for the ingestion layer.

Why Python here and not dbt?  dbt only transforms data that is ALREADY inside the warehouse.
Moving bytes from Postgres to Snowflake is extraction + loading, which is exactly what a small,
boring, well-logged Python job is good at.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")


@dataclass(frozen=True)
class SourceTable:
    """One Postgres table we replicate into Snowflake."""

    schema: str                     # Postgres schema
    name: str                       # Postgres table
    primary_key: tuple[str, ...]    # for dedupe in dbt staging
    cursor_column: str = "updated_at"
    target_schema: str = field(default="")  # Snowflake schema in MERIDIAN_RAW, derived if empty

    @property
    def qualified_source(self) -> str:
        return f"{self.schema}.{self.name}"

    @property
    def snowflake_schema(self) -> str:
        return self.target_schema or f"POSTGRES_{self.schema.upper()}"

    @property
    def snowflake_table(self) -> str:
        return self.name.upper()


# Order matters only for readability; each table is independent (dbt resolves relationships later).
TABLES: tuple[SourceTable, ...] = (
    SourceTable("ref", "currencies", ("currency_code",)),
    SourceTable("ref", "countries", ("country_code",)),
    SourceTable("ref", "channels", ("channel_id",)),
    SourceTable("ref", "products", ("product_id",)),
    SourceTable("ref", "merchants", ("merchant_id",)),
    SourceTable("ref", "sale_events", ("sale_event_id",)),
    SourceTable("ref", "offer_catalog", ("offer_code",)),
    SourceTable("ref", "fx_rates", ("fx_rate_id",)),
    SourceTable("core", "branches", ("branch_id",)),
    SourceTable("core", "employees", ("employee_id",)),
    SourceTable("core", "customers", ("customer_id",)),
    SourceTable("core", "accounts", ("account_id",)),
    SourceTable("core", "account_holders", ("account_id", "customer_id")),
    SourceTable("core", "transactions", ("transaction_id",)),
    SourceTable("core", "loan_applications", ("application_id",)),
    SourceTable("core", "customer_features", ("customer_id",)),
    SourceTable("core", "card_applications", ("application_id",)),
    SourceTable("core", "credit_cards", ("card_id",)),
    SourceTable("core", "card_authorizations", ("authorization_id",)),
    SourceTable("cdc", "deleted_records", ("deleted_record_id",), cursor_column="deleted_at"),
)


@dataclass(frozen=True)
class PostgresConfig:
    host: str = os.getenv("PG_HOST", "localhost")
    port: int = int(os.getenv("PG_PORT", "5432"))
    database: str = os.getenv("PG_DATABASE", "meridian_core")
    user: str = os.getenv("PG_USER", "meridian")
    password: str = os.getenv("PG_PASSWORD", "meridian")

    def dsn(self) -> str:
        return (
            f"host={self.host} port={self.port} dbname={self.database} "
            f"user={self.user} password={self.password} options='-c timezone=UTC'"
        )


@dataclass(frozen=True)
class SnowflakeConfig:
    account: str = os.getenv("SNOWFLAKE_ACCOUNT", "")
    user: str = os.getenv("SNOWFLAKE_USER", "")
    password: str = os.getenv("SNOWFLAKE_PASSWORD", "")
    private_key_path: str = os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", "")
    private_key_passphrase: str = os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "")
    role: str = os.getenv("SNOWFLAKE_ROLE", "MERIDIAN_LOADER")
    warehouse: str = os.getenv("SNOWFLAKE_WAREHOUSE", "WH_INGEST_XS")
    raw_database: str = os.getenv("SNOWFLAKE_RAW_DATABASE", "MERIDIAN_RAW")
    control_schema: str = "CONTROL"
    stage_name: str = "PG_STAGE"           # one internal stage per target schema


@dataclass(frozen=True)
class IngestConfig:
    lag_seconds: int = int(os.getenv("INGEST_LAG_SECONDS", "10"))
    chunk_rows: int = int(os.getenv("INGEST_CHUNK_ROWS", "200000"))
    local_dir: Path = Path(os.getenv("INGEST_LOCAL_DIR", "/tmp/meridian_ingest"))
    initial_watermark: str = "1900-01-01 00:00:00"


PG = PostgresConfig()
SF = SnowflakeConfig()
INGEST = IngestConfig()
