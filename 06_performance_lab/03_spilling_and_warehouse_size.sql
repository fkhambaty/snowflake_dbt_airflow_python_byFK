-- =====================================================================================
--  EXPERIMENT 03 (Snowflake): spilling and warehouse sizing
--
--  When a sort / window / hash join does not fit in the warehouse's memory, Snowflake
--  spills to local SSD (slow) and then to remote storage (very slow). QUERY_HISTORY shows it
--  as bytes_spilled_to_local_storage / bytes_spilled_to_remote_storage.
--  Two fixes, in this order: (1) rewrite the query so it needs less memory, (2) scale up.
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE SCHEMA MERIDIAN_RAW.PERF_LAB;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- ------------------------------------------------------------------ the trap: a global window over 100M rows on XS
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'perflab_03_xs_spill';
SELECT account_id, transaction_ts, amount,
       sum(amount) OVER (ORDER BY transaction_ts, transaction_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM TXN_SORTED
QUALIFY row_number() OVER (ORDER BY transaction_ts DESC) <= 10;
-- A window with ORDER BY and NO PARTITION BY forces one giant sort on a single node.
-- Expect: minutes, GBs spilled (local, maybe remote).

-- ------------------------------------------------------------------ fix 1: rewrite - partition the work
ALTER SESSION SET QUERY_TAG = 'perflab_03_xs_rewrite';
SELECT account_id, transaction_ts, amount,
       sum(amount) OVER (PARTITION BY account_id ORDER BY transaction_ts, transaction_id
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total_per_account
FROM TXN_SORTED
WHERE transaction_date >= dateadd('day', -30, current_date())      -- and prune!
QUALIFY row_number() OVER (PARTITION BY account_id ORDER BY transaction_ts DESC) = 1;
-- PARTITION BY lets every node sort its own slice; the date filter prunes 95% of partitions.
-- Expect: seconds, little or no spill. Same business answer ("latest running total per account").

-- ------------------------------------------------------------------ fix 2: scale up (when the query is already good but the data is simply big)
USE WAREHOUSE WH_TRANSFORM_M;              -- 4x the memory and CPU of XS, 4x the credits per hour
ALTER SESSION SET QUERY_TAG = 'perflab_03_m_spill';
SELECT account_id, transaction_ts, amount,
       sum(amount) OVER (ORDER BY transaction_ts, transaction_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM TXN_SORTED
QUALIFY row_number() OVER (ORDER BY transaction_ts DESC) <= 10;
-- Expect: faster and less spill than XS, but STILL slow: a global ORDER BY cannot be parallelised.
-- Lesson: size fixes memory pressure; it does not fix a serial algorithm. Rewrite first.

-- ------------------------------------------------------------------ the economics (show the maths)
-- XS = 1 credit/hour, M = 4 credits/hour. If M finishes in < 1/4 of the XS time it is CHEAPER
-- to run bigger (per-second billing, 60 s minimum). Compute it from the measurements:
SELECT query_tag, warehouse_size, total_elapsed_time/1000 AS seconds,
       CASE warehouse_size WHEN 'X-Small' THEN 1 WHEN 'Small' THEN 2 WHEN 'Medium' THEN 4 WHEN 'Large' THEN 8 END AS credits_per_hour,
       round(greatest(total_elapsed_time/1000, 60) / 3600 *
             CASE warehouse_size WHEN 'X-Small' THEN 1 WHEN 'Small' THEN 2 WHEN 'Medium' THEN 4 WHEN 'Large' THEN 8 END, 4) AS credits_for_this_query,
       round((bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage)/1048576) AS mb_spilled
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_tag LIKE 'perflab_03_%' AND query_type = 'SELECT'
QUALIFY row_number() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1
ORDER BY query_tag;

USE WAREHOUSE WH_TRANSFORM_XS;
ALTER WAREHOUSE WH_TRANSFORM_M SUSPEND;
