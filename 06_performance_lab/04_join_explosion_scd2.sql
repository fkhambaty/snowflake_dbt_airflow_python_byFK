-- =====================================================================================
--  EXPERIMENT 04 (Snowflake + modelling): the SCD2 fan-out
--
--  dim_customer has several rows per customer (one per version). Joining a fact to it on
--  customer_id ALONE multiplies every transaction by the number of versions. Totals inflate,
--  the query gets slower, and nobody notices until finance does.
--  Prerequisite: run the simulator for a while + `dbt snapshot` twice so customers have >1 version.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE DATABASE MERIDIAN_ANALYTICS;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- How many customers have multiple versions?
SELECT count(*) AS customers, sum(iff(versions > 1, 1, 0)) AS with_history, max(versions) AS max_versions
FROM (SELECT customer_id, count(*) AS versions FROM MARTS.DIM_CUSTOMER GROUP BY 1);

-- Baseline: the truth
ALTER SESSION SET QUERY_TAG = 'perflab_04_truth';
SELECT count(*) AS rows_, sum(amount_reporting) AS deposits_usd
FROM MARTS.FCT_TRANSACTIONS
WHERE transaction_type = 'DEPOSIT' AND status = 'POSTED';

-- THE TRAP: join on the natural key only
ALTER SESSION SET QUERY_TAG = 'perflab_04_fanout';
SELECT count(*) AS rows_, sum(f.amount_reporting) AS deposits_usd
FROM MARTS.FCT_TRANSACTIONS f
JOIN MARTS.DIM_CUSTOMER c ON c.customer_id = f.customer_id          -- <-- no version predicate
WHERE f.transaction_type = 'DEPOSIT' AND f.status = 'POSTED';
-- rows_ and deposits_usd are LARGER than the truth. Every customer with 3 versions counts 3x.

-- FIX A: point-in-time predicate (what fct_transactions does at build time)
ALTER SESSION SET QUERY_TAG = 'perflab_04_pit';
SELECT count(*) AS rows_, sum(f.amount_reporting) AS deposits_usd
FROM MARTS.FCT_TRANSACTIONS f
JOIN MARTS.DIM_CUSTOMER c ON c.customer_id = f.customer_id
                         AND f.transaction_ts >= c.valid_from
                         AND f.transaction_ts <  c.valid_to
WHERE f.transaction_type = 'DEPOSIT' AND f.status = 'POSTED';

-- FIX B (preferred for BI): join on the SURROGATE key that was resolved once, at load time
ALTER SESSION SET QUERY_TAG = 'perflab_04_surrogate';
SELECT count(*) AS rows_, sum(f.amount_reporting) AS deposits_usd
FROM MARTS.FCT_TRANSACTIONS f
JOIN MARTS.DIM_CUSTOMER c ON c.customer_key = f.customer_key
WHERE f.transaction_type = 'DEPOSIT' AND f.status = 'POSTED';
-- Equality join on one column: fastest, and impossible to get wrong in a dashboard.

-- FIX C: "current attributes" view when the business wants Type 1 behaviour over a Type 2 dim
ALTER SESSION SET QUERY_TAG = 'perflab_04_current';
SELECT c.segment, sum(f.amount_reporting) AS deposits_usd
FROM MARTS.FCT_TRANSACTIONS f
JOIN MARTS.DIM_CUSTOMER c ON c.customer_id = f.customer_id AND c.is_current
WHERE f.transaction_type = 'DEPOSIT' AND f.status = 'POSTED'
GROUP BY 1;

-- The dbt singular test tests/assert_fct_transactions_reconciles_to_staging.sql catches the
-- fan-out automatically if someone removes the scd2_match() predicate from fct_transactions.
-- Show it: comment the predicate out, dbt build, watch the test fail, put it back.
