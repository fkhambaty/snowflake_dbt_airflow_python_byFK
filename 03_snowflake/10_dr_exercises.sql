-- =====================================================================================
--  Recovery drill in a disposable schema. Run as MERIDIAN_TRANSFORMER after a prod build.
--  No production object is changed. Capture query ids and elapsed time for the DR evidence.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;

CREATE OR REPLACE SCHEMA MERIDIAN_ANALYTICS.DR_EXERCISE
  DATA_RETENTION_TIME_IN_DAYS = 1;

-- 1. Baseline and zero-copy safety copy.
CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK AS
SELECT * FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS LIMIT 10000;

CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_GOOD
  CLONE MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK;

SET baseline_rows = (
  SELECT count(*) FROM MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK
);

-- 2. Operator mistake, then statement-level Time Travel proof.
UPDATE MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK
SET amount_reporting = amount_reporting * 1000;
SET bad_statement_id = LAST_QUERY_ID();

SELECT transaction_id, amount_reporting
FROM MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK
  BEFORE (STATEMENT => $bad_statement_id)
ORDER BY transaction_id
LIMIT 10;

-- 3. Fast rollback: verify the good clone, then atomically swap names.
SELECT count(*) AS rows_before_swap
FROM MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_GOOD;

ALTER TABLE MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK
  SWAP WITH MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_GOOD;

SELECT count(*) = $baseline_rows AS row_count_recovered
FROM MERIDIAN_ANALYTICS.DR_EXERCISE.TRANSACTIONS_WORK;

-- 4. Accidental DROP and UNDROP.
CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.DR_EXERCISE.UNDROP_ME AS
SELECT current_timestamp() AS created_at;
DROP TABLE MERIDIAN_ANALYTICS.DR_EXERCISE.UNDROP_ME;
UNDROP TABLE MERIDIAN_ANALYTICS.DR_EXERCISE.UNDROP_ME;
SELECT * FROM MERIDIAN_ANALYTICS.DR_EXERCISE.UNDROP_ME;

-- 5. Logical recovery remains the authoritative path for derived data:
--      dbt build --select fct_transactions+ --full-refresh --target prod
--      python 02_ingestion_python/reconcile_with_pandas.py --days 30 --record
--      dbt run-operation apply_governance_all --target prod
-- Marts are rebuilt from append-only raw; Time Travel is the fast diagnostic/rollback tool.

DROP SCHEMA MERIDIAN_ANALYTICS.DR_EXERCISE;
