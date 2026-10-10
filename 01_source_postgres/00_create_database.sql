-- Execute this in DBeaver while the connection database is postgres.
-- Turn on Auto-commit first. CREATE DATABASE cannot run inside a transaction.
-- If Postgres says the database already exists, that is fine: switch the
-- connection to meridian_core and continue with 01_ddl_core_schema.sql.

CREATE DATABASE meridian_core;

COMMENT ON DATABASE meridian_core IS
  'Meridian Bank core banking OLTP system (teaching replica). Source for the Snowflake warehouse.';
