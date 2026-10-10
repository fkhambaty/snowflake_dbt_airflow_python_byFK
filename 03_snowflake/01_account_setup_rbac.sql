-- =====================================================================================
--  Snowflake bootstrap 1/3 : roles, warehouses, service users, resource monitor
--  Run as ACCOUNTADMIN in a Snowsight worksheet, top to bottom.
--
--  Trial tip: choose ENTERPRISE edition when you sign up (same free credits) so that
--  Search Optimization, Materialized Views, multi-cluster warehouses and 90-day Time Travel
--  are available for the performance lab.
--
--  RBAC design (functional roles, least privilege, interview favourite):
--    MERIDIAN_LOADER       -> writes raw, owns stages & control tables (used by Python/Airflow)
--    MERIDIAN_TRANSFORMER  -> reads raw, owns MERIDIAN_ANALYTICS (used by dbt)
--    MERIDIAN_ANALYST      -> read-only on MARTS, whole bank (BI tools, central analytics)
--    MERIDIAN_ML           -> reads gold features, writes MERIDIAN_RAW.ML (the training job)
--    MERIDIAN_APP          -> owns the Streamlit app; sees nothing unless the viewer may
--  Persona roles for the English app. Which ROWS they see is decided by row access
--  policies keyed on the user (06_row_level_security.sql), not by these roles:
--    MERIDIAN_CEO, MERIDIAN_BRANCH_MANAGER, MERIDIAN_STAFF, MERIDIAN_CUSTOMER
--  SYSADMIN inherits the functional roles so admins can operate everything.
--  Object grants on marts are declared in dbt (`grants:` config), not here.
-- =====================================================================================
USE ROLE ACCOUNTADMIN;

-- ------------------------------------------------------------------ roles
CREATE ROLE IF NOT EXISTS MERIDIAN_LOADER       COMMENT = 'Ingestion service: PUT/COPY into MERIDIAN_RAW';
CREATE ROLE IF NOT EXISTS MERIDIAN_TRANSFORMER  COMMENT = 'dbt: builds MERIDIAN_ANALYTICS from MERIDIAN_RAW';
CREATE ROLE IF NOT EXISTS MERIDIAN_ANALYST      COMMENT = 'Read-only consumer of MARTS, whole bank';
CREATE ROLE IF NOT EXISTS MERIDIAN_ML           COMMENT = 'Training job: reads gold, writes MERIDIAN_RAW.ML';
CREATE ROLE IF NOT EXISTS MERIDIAN_APP          COMMENT = 'Owner of the Streamlit app. Row policies deny it by default.';
CREATE ROLE IF NOT EXISTS MERIDIAN_CEO             COMMENT = 'Persona: whole bank';
CREATE ROLE IF NOT EXISTS MERIDIAN_BRANCH_MANAGER  COMMENT = 'Persona: one branch';
CREATE ROLE IF NOT EXISTS MERIDIAN_STAFF           COMMENT = 'Persona: one branch, PII masked';
CREATE ROLE IF NOT EXISTS MERIDIAN_CUSTOMER        COMMENT = 'Persona: own rows';

GRANT ROLE MERIDIAN_LOADER      TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_TRANSFORMER TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_ML          TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_APP         TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_ANALYST     TO ROLE MERIDIAN_TRANSFORMER;   -- transformer can see what analysts see
GRANT ROLE MERIDIAN_CEO            TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_BRANCH_MANAGER TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_STAFF          TO ROLE SYSADMIN;
GRANT ROLE MERIDIAN_CUSTOMER       TO ROLE SYSADMIN;

-- ------------------------------------------------------------------ warehouses (separate by workload!)
-- Separate warehouses = separate caches, separate cost attribution, no queueing between workloads.
CREATE WAREHOUSE IF NOT EXISTS WH_INGEST_XS     WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60  AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE COMMENT = 'COPY INTO raw';
CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM_XS  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60  AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE COMMENT = 'dbt default';
CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM_M   WAREHOUSE_SIZE = MEDIUM AUTO_SUSPEND = 60  AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE COMMENT = 'Performance lab: scale-up experiments';
CREATE WAREHOUSE IF NOT EXISTS WH_BI_XS         WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 120 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE COMMENT = 'Dashboards & ad hoc';

GRANT USAGE, OPERATE ON WAREHOUSE WH_INGEST_XS    TO ROLE MERIDIAN_LOADER;
GRANT USAGE, OPERATE ON WAREHOUSE WH_TRANSFORM_XS TO ROLE MERIDIAN_TRANSFORMER;
GRANT USAGE, OPERATE ON WAREHOUSE WH_TRANSFORM_M  TO ROLE MERIDIAN_TRANSFORMER;
GRANT USAGE          ON WAREHOUSE WH_BI_XS        TO ROLE MERIDIAN_ANALYST;
GRANT USAGE          ON WAREHOUSE WH_TRANSFORM_XS TO ROLE MERIDIAN_ML;
GRANT USAGE          ON WAREHOUSE WH_BI_XS        TO ROLE MERIDIAN_APP;
GRANT USAGE          ON WAREHOUSE WH_BI_XS        TO ROLE MERIDIAN_CEO;
GRANT USAGE          ON WAREHOUSE WH_BI_XS        TO ROLE MERIDIAN_BRANCH_MANAGER;
GRANT USAGE          ON WAREHOUSE WH_BI_XS        TO ROLE MERIDIAN_STAFF;
GRANT USAGE          ON WAREHOUSE WH_BI_XS        TO ROLE MERIDIAN_CUSTOMER;

-- ------------------------------------------------------------------ resource monitor: protect the free credits
CREATE RESOURCE MONITOR IF NOT EXISTS RM_MERIDIAN_TRIAL
  WITH CREDIT_QUOTA = 100
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 90 PERCENT DO SUSPEND
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER WAREHOUSE WH_INGEST_XS    SET RESOURCE_MONITOR = RM_MERIDIAN_TRIAL;
ALTER WAREHOUSE WH_TRANSFORM_XS SET RESOURCE_MONITOR = RM_MERIDIAN_TRIAL;
ALTER WAREHOUSE WH_TRANSFORM_M  SET RESOURCE_MONITOR = RM_MERIDIAN_TRIAL;
ALTER WAREHOUSE WH_BI_XS        SET RESOURCE_MONITOR = RM_MERIDIAN_TRIAL;

-- ------------------------------------------------------------------ service users (key-pair auth)
-- Generate keys locally first:
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.ssh/meridian_rsa_key.p8 -nocrypt
--   openssl rsa -in ~/.ssh/meridian_rsa_key.p8 -pubout -out ~/.ssh/meridian_rsa_key.pub
-- Then paste the body of the .pub (without BEGIN/END lines) below.
CREATE USER IF NOT EXISTS MERIDIAN_LOADER_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = MERIDIAN_LOADER
  DEFAULT_WAREHOUSE = WH_INGEST_XS
  COMMENT = 'Python/Airflow ingestion';
-- ALTER USER MERIDIAN_LOADER_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
GRANT ROLE MERIDIAN_LOADER TO USER MERIDIAN_LOADER_SVC;

CREATE USER IF NOT EXISTS MERIDIAN_DBT_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = MERIDIAN_TRANSFORMER
  DEFAULT_WAREHOUSE = WH_TRANSFORM_XS
  COMMENT = 'dbt runs from Airflow / CI';
-- ALTER USER MERIDIAN_DBT_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
GRANT ROLE MERIDIAN_TRANSFORMER TO USER MERIDIAN_DBT_SVC;

CREATE USER IF NOT EXISTS MERIDIAN_ML_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = MERIDIAN_ML
  DEFAULT_WAREHOUSE = WH_TRANSFORM_XS
  COMMENT = 'Weekly model training from Airflow';
-- ALTER USER MERIDIAN_ML_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
GRANT ROLE MERIDIAN_ML TO USER MERIDIAN_ML_SVC;

-- Your own human user gets the functional roles for the demos:
-- GRANT ROLE MERIDIAN_LOADER, MERIDIAN_TRANSFORMER, MERIDIAN_ANALYST, MERIDIAN_ML, MERIDIAN_APP TO USER <your_user>;

-- ------------------------------------------------------------------ account-level hygiene
ALTER ACCOUNT SET TIMEZONE = 'UTC';                          -- the warehouse speaks UTC
ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;       -- nothing runs for more than an hour by accident

SHOW ROLES LIKE 'MERIDIAN%';
SHOW WAREHOUSES LIKE 'WH_%';
