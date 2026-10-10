-- =====================================================================================
--  Snowflake bootstrap 2/3 : databases, schemas, grants (incl. future grants)
--
--  MERIDIAN_RAW         landing zone, owned by LOADER, append-only VARIANT tables
--    .POSTGRES_CORE     mirrors Postgres schema core
--    .POSTGRES_REF      mirrors Postgres schema ref
--    .POSTGRES_CDC      mirrors Postgres schema cdc (delete log)
--    .CONTROL           watermarks + load log
--    .PERF_LAB          synthetic big tables for the performance episode
--  MERIDIAN_ANALYTICS   dbt-owned. dbt creates STAGING / INTERMEDIATE / MARTS / SNAPSHOTS
--                       in prod, and DBT_<USER>_* schemas in dev (see macros/generate_schema_name.sql)
-- =====================================================================================
USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS MERIDIAN_RAW       COMMENT = 'Landing zone replicated from Postgres (append-only)';
CREATE DATABASE IF NOT EXISTS MERIDIAN_ANALYTICS COMMENT = 'dbt-managed warehouse (staging -> intermediate -> marts)';

CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.POSTGRES_CORE;
CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.POSTGRES_REF;
CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.POSTGRES_CDC;
CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.CONTROL;
CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.PERF_LAB;

-- Time Travel: raw keeps 7 days (cheap insurance), analytics default 1 day (dbt rebuilds anyway)
ALTER DATABASE MERIDIAN_RAW SET DATA_RETENTION_TIME_IN_DAYS = 7;

-- ------------------------------------------------------------------ ownership & grants: RAW
GRANT OWNERSHIP ON DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_LOADER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_LOADER COPY CURRENT GRANTS;

GRANT USAGE ON DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_TRANSFORMER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_TRANSFORMER;
GRANT SELECT ON ALL TABLES IN DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_TRANSFORMER;   -- future grants = no re-granting after each new table
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_TRANSFORMER;

-- ------------------------------------------------------------------ ownership & grants: ANALYTICS
GRANT OWNERSHIP ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_TRANSFORMER COPY CURRENT GRANTS;

-- Consumers get USAGE here and SELECT from dbt's `grants:` config on each mart.
-- No database-wide FUTURE grant on tables: that would hand analysts every staging
-- table too, including raw email and phone, with no row policy on it.
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_ANALYST;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_ML;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_APP;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_CEO;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_BRANCH_MANAGER;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_STAFF;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_CUSTOMER;

GRANT USAGE ON DATABASE MERIDIAN_RAW TO ROLE MERIDIAN_ML;

-- ------------------------------------------------------------------ sanity
SHOW GRANTS ON DATABASE MERIDIAN_RAW;
SHOW GRANTS TO ROLE MERIDIAN_TRANSFORMER;
