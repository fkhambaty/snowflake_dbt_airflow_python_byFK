-- =====================================================================================
--  Time Travel, UNDROP, Zero-copy Clone, Query History (Episode 3 closing demo)
--  Each block answers a classic interview question.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;

-- Q: "Someone ran a bad UPDATE on a fact table 10 minutes ago. How do you recover?"
SELECT count(*) FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS AT (OFFSET => -600);        -- 10 minutes ago
SELECT count(*) FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS BEFORE (STATEMENT => '<query_id>');

-- Restore: swap in a clone from the past (atomic rename, no copy of data)
-- CREATE TABLE MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS_RESTORED CLONE MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS AT (OFFSET => -600);
-- ALTER TABLE MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS SWAP WITH MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS_RESTORED;

-- Q: "A table was dropped."
-- DROP TABLE MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH;  UNDROP TABLE MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH;

-- Q: "How do you give every developer a full-size copy of prod without paying for storage twice?"
CREATE DATABASE IF NOT EXISTS MERIDIAN_ANALYTICS_DEV_FK CLONE MERIDIAN_ANALYTICS;    -- seconds, zero extra bytes until modified
-- dbt dev target points at the clone; prod stays untouched.

-- Q: "Show me every query that scanned more than 1 GB today and whether it spilled."
SELECT query_id, user_name, warehouse_name, warehouse_size,
       total_elapsed_time / 1000             AS seconds,
       bytes_scanned / power(1024, 3)        AS gb_scanned,
       partitions_scanned, partitions_total,
       bytes_spilled_to_local_storage, bytes_spilled_to_remote_storage,
       query_tag,
       left(query_text, 120)                 AS query_text
FROM TABLE(MERIDIAN_ANALYTICS.INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 1000))
WHERE start_time >= dateadd('day', -1, current_timestamp())
  AND bytes_scanned > power(1024, 3)
ORDER BY bytes_scanned DESC;
-- INFORMATION_SCHEMA.QUERY_HISTORY = last 7 days, instant.  SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY = 1 year, ~45 min latency.

-- Q: "What does this table cost me?"
SELECT table_catalog, table_schema, table_name,
       round(active_bytes / power(1024,3), 2)        AS active_gb,
       round(time_travel_bytes / power(1024,3), 2)   AS time_travel_gb,
       round(failsafe_bytes / power(1024,3), 2)      AS failsafe_gb
FROM MERIDIAN_ANALYTICS.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE table_schema = 'MARTS'
ORDER BY active_bytes DESC;
