-- =====================================================================================
--  EXPERIMENT 05 (Snowflake): the three caches, and why "it was fast the second time" means nothing
--
--  1. Result cache   (cloud services) : identical query text + unchanged data -> 0 compute, ~100 ms
--  2. Local disk cache (warehouse)    : micro-partitions already on the warehouse's SSD
--  3. Metadata cache (cloud services) : count(*), min/max answered without a warehouse at all
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE SCHEMA MERIDIAN_RAW.PERF_LAB;

-- ------------------------------------------------------------------ 1. result cache
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
ALTER SESSION SET QUERY_TAG = 'perflab_05_result_cold';
SELECT currency_code, count(*), sum(amount) FROM TXN_SORTED WHERE transaction_date >= dateadd('day', -30, current_date()) GROUP BY 1;

ALTER SESSION SET QUERY_TAG = 'perflab_05_result_hit';
SELECT currency_code, count(*), sum(amount) FROM TXN_SORTED WHERE transaction_date >= dateadd('day', -30, current_date()) GROUP BY 1;
-- Second run: ~100 ms, bytes_scanned = 0, Query Profile says "QUERY RESULT REUSE".
-- Any change (a new row, a different alias, extra whitespace inside a literal) invalidates it.

-- ------------------------------------------------------------------ 2. warehouse local disk cache
ALTER SESSION SET USE_CACHED_RESULT = FALSE;         -- disable result cache to see the next layer
ALTER WAREHOUSE WH_TRANSFORM_XS SUSPEND;              -- drops the local disk cache
ALTER WAREHOUSE WH_TRANSFORM_XS RESUME;

ALTER SESSION SET QUERY_TAG = 'perflab_05_disk_cold';
SELECT branch_id, count(*) FROM TXN_SORTED WHERE transaction_date >= dateadd('day', -30, current_date()) GROUP BY 1;

ALTER SESSION SET QUERY_TAG = 'perflab_05_disk_warm';
SELECT branch_id, count(*) FROM TXN_SORTED WHERE transaction_date >= dateadd('day', -30, current_date()) GROUP BY 1;
-- Same bytes_scanned both times, but the warm run reads from SSD instead of remote storage:
-- Query Profile -> "Percentage scanned from cache". Typically 2-5x faster.
-- Implication: AUTO_SUSPEND too aggressive (e.g. 10 s) throws this cache away constantly.

-- ------------------------------------------------------------------ 3. metadata cache
ALTER SESSION SET QUERY_TAG = 'perflab_05_metadata';
SELECT count(*), min(transaction_date), max(transaction_date) FROM TXN_SORTED;
-- Instant, even with the result cache off: answered from micro-partition metadata.
-- Add a WHERE clause or a count(DISTINCT) and it becomes a real scan.

-- ------------------------------------------------------------------ read the numbers
SELECT query_tag, total_elapsed_time AS ms, round(bytes_scanned/1048576) AS mb_scanned,
       percentage_scanned_from_cache
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_tag LIKE 'perflab_05_%' AND query_type = 'SELECT'
QUALIFY row_number() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1
ORDER BY start_time;
