-- =====================================================================================
--  Disposable developer database from a zero-copy production clone.
--
--  Run as MERIDIAN_TRANSFORMER. The clone initially shares micro-partitions with prod;
--  only changed data consumes storage. Never point an app at it and never clone RAW secrets.
--  Durable platform objects remain Terraform-owned. This database is disposable test state.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;

-- Use a safe, reviewed identifier. CI substitutes its PR/run id before executing the script.
SET dev_database = 'MERIDIAN_ANALYTICS_DEV_FK';

CREATE OR REPLACE DATABASE IDENTIFIER($dev_database)
  CLONE MERIDIAN_ANALYTICS
  COMMENT = 'Disposable zero-copy developer clone; no production consumers';

ALTER DATABASE IDENTIFIER($dev_database) SET DATA_RETENTION_TIME_IN_DAYS = 1;

-- Point the `dev_clone` dbt target at the same name:
--   export DBT_CLONE_DATABASE=MERIDIAN_ANALYTICS_DEV_FK
--   dbt build --target dev_clone --select state:modified+
--
-- Writes made by dbt are isolated from production. Reads of untouched cloned tables use
-- the clone snapshot, unlike --defer, which reads current production upstreams.

SHOW DATABASES LIKE 'MERIDIAN_ANALYTICS_DEV_FK';

-- Cleanup is mandatory. Zero-copy is not zero-retention.
-- DROP DATABASE IF EXISTS IDENTIFIER($dev_database);
