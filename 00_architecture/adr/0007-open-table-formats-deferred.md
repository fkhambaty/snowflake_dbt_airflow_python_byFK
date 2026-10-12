# 0007. Open table formats (Apache Iceberg) deferred

**Status:** Accepted

## Context
Iceberg tables let several engines (Spark, Trino, DuckDB, Snowflake) read and write the
same data in object storage without copying it. Every architecture interview now asks
about the "lakehouse".

## Decision
All tables stay Snowflake-native for v1. The trigger to adopt Iceberg is written down
below, so it is a decision with a revisit condition, not an omission.

## Reasoning
* Today there is exactly one engine. Iceberg's main benefit, engine independence, is worth zero.
* Its costs are real: an external volume, a catalog choice (Snowflake-managed, Polaris/Open
  Catalog, Glue), file compaction and snapshot expiry to operate, and fewer native features
  on some table types.

## Revisit when (any one is enough)
* A second engine needs the same data, for example a data science team on Spark/Databricks.
* A regulator or contract requires data to sit in the bank's own storage account in an open format.
* Snowflake egress or storage cost for a large append-only table (raw transactions) passes
  the cost of operating it as Iceberg.

## First candidate
`MERIDIAN_RAW.POSTGRES_CORE.TRANSACTIONS`. It is append-only and large, and other engines
would want it. Marts stay native.
