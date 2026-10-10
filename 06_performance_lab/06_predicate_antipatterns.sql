-- =====================================================================================
--  EXPERIMENT 06 (Snowflake SQL): four everyday anti-patterns, each with a measurable fix
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE SCHEMA MERIDIAN_RAW.PERF_LAB;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- ------------------------------------------------------------------ A. function on the filtered column kills pruning
ALTER SESSION SET QUERY_TAG = 'perflab_06a_bad';
SELECT count(*), sum(amount) FROM TXN_SORTED
WHERE to_char(transaction_ts, 'YYYY-MM') = to_char(dateadd('month', -1, current_date()), 'YYYY-MM');
-- Snowflake cannot use min/max metadata on to_char(...). Full scan.

ALTER SESSION SET QUERY_TAG = 'perflab_06a_good';
SELECT count(*), sum(amount) FROM TXN_SORTED
WHERE transaction_date >= date_trunc('month', dateadd('month', -1, current_date()))
  AND transaction_date <  date_trunc('month', current_date());
-- A range on the raw (clustered) column prunes ~94% of partitions.

-- ------------------------------------------------------------------ B. SELECT * on a columnar store
ALTER SESSION SET QUERY_TAG = 'perflab_06b_bad';
SELECT * FROM TXN_SORTED WHERE transaction_date = dateadd('day', -3, current_date()) AND amount > 4900;

ALTER SESSION SET QUERY_TAG = 'perflab_06b_good';
SELECT transaction_id, account_id, amount FROM TXN_SORTED WHERE transaction_date = dateadd('day', -3, current_date()) AND amount > 4900;
-- Columnar storage reads only the columns you name. Fewer columns = fewer bytes = faster.
-- (reference_no is a 16-char random string: the most expensive column in the table.)

-- ------------------------------------------------------------------ C. UNION vs UNION ALL
ALTER SESSION SET QUERY_TAG = 'perflab_06c_bad';
SELECT account_id, amount FROM TXN_SORTED WHERE transaction_date = dateadd('day', -1, current_date())
UNION
SELECT account_id, amount FROM TXN_SORTED WHERE transaction_date = dateadd('day', -2, current_date());
-- UNION = UNION ALL + DISTINCT over the whole result. The two days cannot overlap -> the DISTINCT is pure waste.

ALTER SESSION SET QUERY_TAG = 'perflab_06c_good';
SELECT account_id, amount FROM TXN_SORTED WHERE transaction_date = dateadd('day', -1, current_date())
UNION ALL
SELECT account_id, amount FROM TXN_SORTED WHERE transaction_date = dateadd('day', -2, current_date());

-- ------------------------------------------------------------------ D. DISTINCT as a bandage for a fan-out join
-- "I got duplicates so I added DISTINCT" hides the bug AND adds a sort/hash over the whole result.
ALTER SESSION SET QUERY_TAG = 'perflab_06d_bad';
SELECT DISTINCT t.transaction_id, t.amount
FROM TXN_SORTED t
JOIN (SELECT branch_id FROM TXN_SORTED WHERE transaction_date = current_date() - 1) b ON b.branch_id = t.branch_id   -- many rows per branch!
WHERE t.transaction_date = current_date() - 1;

ALTER SESSION SET QUERY_TAG = 'perflab_06d_good';
SELECT t.transaction_id, t.amount
FROM TXN_SORTED t
WHERE t.transaction_date = current_date() - 1
  AND EXISTS (SELECT 1 FROM TXN_SORTED b WHERE b.branch_id = t.branch_id AND b.transaction_date = current_date() - 1);
-- EXISTS asks the question you meant ("is there at least one") and never multiplies rows.

-- ------------------------------------------------------------------ read the numbers
SELECT query_tag, total_elapsed_time AS ms, round(bytes_scanned/1048576) AS mb_scanned,
       partitions_scanned || '/' || partitions_total AS partitions, rows_produced
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_tag LIKE 'perflab_06%' AND query_type = 'SELECT'
QUALIFY row_number() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1
ORDER BY query_tag;
