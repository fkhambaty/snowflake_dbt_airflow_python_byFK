-- =====================================================================================
--  EXPERIMENT 07 (Snowflake, Enterprise edition): point lookups and pre-aggregation
--
--  Clustering helps RANGE scans on one key. Two other access patterns need other tools:
--    * needle-in-haystack lookups (reference_no = 'ABC...')  -> Search Optimization Service
--    * the same heavy aggregate asked 500 times a day       -> Materialized View
--  Both cost credits to maintain -> use them where the measurement justifies it.
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE SCHEMA MERIDIAN_RAW.PERF_LAB;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- pick a real needle
SET needle = (SELECT reference_no FROM TXN_SORTED SAMPLE (10 ROWS) LIMIT 1);

-- ------------------------------------------------------------------ A. point lookup BEFORE
ALTER SESSION SET QUERY_TAG = 'perflab_07a_before';
SELECT * FROM TXN_SORTED WHERE reference_no = $needle;
-- reference_no is random -> every micro-partition's min/max covers it -> full scan of 100M rows.

-- enable SOS (background build takes a few minutes; check progress)
ALTER TABLE TXN_SORTED ADD SEARCH OPTIMIZATION ON EQUALITY(reference_no, transaction_id);
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS('TXN_SORTED');     -- always estimate first
SHOW TABLES LIKE 'TXN_SORTED';   -- column search_optimization_progress -> wait for 100

ALTER SESSION SET QUERY_TAG = 'perflab_07a_after';
SELECT * FROM TXN_SORTED WHERE reference_no = $needle;
-- Expect: from 10-30 s to well under 1 s; partitions_scanned drops to a handful.

-- ------------------------------------------------------------------ A2. "part of an id" is a different access path
-- Equality SOS does not accelerate ILIKE / CONTAINS. Say that, then prove it.
ALTER SESSION SET QUERY_TAG = 'perflab_07a2_before';
SET fragment = (SELECT substr(reference_no, 3, 6) FROM TXN_SORTED WHERE reference_no = $needle);
SELECT count(*) FROM TXN_SORTED WHERE CONTAINS(reference_no, $fragment);

ALTER TABLE TXN_SORTED ADD SEARCH OPTIMIZATION ON SUBSTRING(reference_no);
-- Wait again for search_optimization_progress = 100. The substring path is a second build.

ALTER SESSION SET QUERY_TAG = 'perflab_07a2_after';
SELECT count(*) FROM TXN_SORTED WHERE CONTAINS(reference_no, $fragment);
-- The production version of this predicate is MARTS.OMNI_SEARCH (ADR 0009),
-- enabled by 03_snowflake/07_omni_search.sql. Do not wrap the column in UPPER():
-- a function on the column makes Snowflake ignore the access path.

-- ------------------------------------------------------------------ B. materialized view for a hot aggregate
ALTER SESSION SET QUERY_TAG = 'perflab_07b_before';
SELECT transaction_date, currency_code, count(*) AS txns, sum(amount) AS total
FROM TXN_SORTED GROUP BY 1, 2 ORDER BY 1 DESC, 2 LIMIT 20;

CREATE OR REPLACE MATERIALIZED VIEW MV_DAILY_CURRENCY_TOTALS AS
SELECT transaction_date, currency_code, count(*) AS txns, sum(amount) AS total
FROM TXN_SORTED GROUP BY 1, 2;

ALTER SESSION SET QUERY_TAG = 'perflab_07b_after';
SELECT transaction_date, currency_code, txns, total
FROM MV_DAILY_CURRENCY_TOTALS ORDER BY 1 DESC, 2 LIMIT 20;
-- The optimizer will even rewrite the ORIGINAL query against TXN_SORTED to use the MV transparently.
-- MVs are maintained automatically on every DML to the base table (credits!). They cannot have
-- joins or window functions -> for anything richer, use a dbt aggregate model (agg_branch_daily_performance)
-- or a Dynamic Table.

-- ------------------------------------------------------------------ read the numbers
SELECT query_tag, total_elapsed_time AS ms, round(bytes_scanned/1048576) AS mb_scanned,
       partitions_scanned || '/' || partitions_total AS partitions
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_tag LIKE 'perflab_07%' AND query_type = 'SELECT'
QUALIFY row_number() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1
ORDER BY query_tag;

-- Cleanup (both features bill while they exist):
-- ALTER TABLE TXN_SORTED DROP SEARCH OPTIMIZATION;  DROP MATERIALIZED VIEW MV_DAILY_CURRENCY_TOTALS;
