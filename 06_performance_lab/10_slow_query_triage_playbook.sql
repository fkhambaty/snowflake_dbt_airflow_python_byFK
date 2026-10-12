-- =====================================================================================
--  EXPERIMENT 10: slow-query triage, in order
--
--  Do these steps in this order. Skipping ahead is how a warehouse gets resized for
--  a query that was waiting in a queue, or rewritten for a join that fanned out.
--
--    1. Turn the result cache off. A second run of the same text is otherwise a lie.
--    2. Read QUERY_HISTORY ordered slowest first, then fastest first, with a fast
--       peer beside the slow query.
--    3. Split queue time from execution time. Queue time is not execution time.
--    4. Open the profile of the slow query. Find the widest operator and its rows
--       in and rows out.
--    5. Classify, and only then change something:
--         queue  > execution     -> scale out (more clusters). Lab 09.
--         spill bytes            -> rewrite, then scale up if it still spills. Lab 03.
--         partitions scanned
--           = partitions total   -> not pruning. Labs 02 and 06.
--         join rows out / rows in
--           above 1              -> grain error. Lab 04.
--         none of the above      -> scale up. Lab 03.
--    6. Rerun under a new query tag and compare. Result cache stays off.
--       Warehouse disk cache can still shrink bytes_scanned on the rerun. That is
--       lab 05, not a fix. Suspend the warehouse there if you need a cold cache.
--
--  INFORMATION_SCHEMA is immediate. ACCOUNT_USAGE.QUERY_HISTORY lags about 45 minutes.
--  This script uses the session history of the probes below, so it runs without the
--  100M-row lab tables. When those tables exist, point the same queries at their tags.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE DATABASE MERIDIAN_ANALYTICS;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- ------------------------------------------------------------------ 1 and 2. Fast probe, then slow probe
ALTER SESSION SET QUERY_TAG = 'perflab_10_fast';
SELECT COUNT(*) AS fast_rows
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'perflab_10_slow';
SELECT COUNT(*) AS slow_rows
FROM (
    SELECT SEQ4() AS id
    FROM TABLE(GENERATOR(ROWCOUNT => 200000))
) ones
JOIN (
    SELECT SEQ4() AS id
    FROM TABLE(GENERATOR(ROWCOUNT => 10))
) tens
    ON TRUE;
-- 200,000 x 10 = 2,000,000. The join multiplies on purpose so the profile shows
-- rows out greater than rows in. A real fact should come back to a multiplier of 1.

-- Capture the slow SELECT, not the statement that stores the id.
SET slow_query_id = LAST_QUERY_ID();

-- ------------------------------------------------------------------ 3. History: slowest first, then fastest first
SELECT
    query_tag,
    query_id,
    warehouse_size,
    total_elapsed_time AS elapsed_ms,
    execution_time AS execution_ms,
    compilation_time AS compilation_ms,
    queued_overload_time
        + queued_provisioning_time
        + queued_repair_time AS queue_ms,
    queued_overload_time,
    partitions_scanned,
    partitions_total,
    bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage AS spill_bytes,
    rows_produced
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
WHERE query_tag IN ('perflab_10_fast', 'perflab_10_slow')
  AND query_type = 'SELECT'
ORDER BY total_elapsed_time DESC;

SELECT
    query_tag,
    total_elapsed_time AS elapsed_ms,
    execution_time AS execution_ms
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
WHERE query_tag IN ('perflab_10_fast', 'perflab_10_slow')
  AND query_type = 'SELECT'
ORDER BY total_elapsed_time ASC;

-- ------------------------------------------------------------------ 4. Queue time versus execution time
-- One session does not queue behind itself, so queue_ms here is often 0.
-- Lab 09 creates a real queue. The CASE is the same one you apply there.
SELECT
    query_id,
    query_tag,
    total_elapsed_time AS elapsed_ms,
    execution_time AS execution_ms,
    queued_overload_time + queued_provisioning_time + queued_repair_time AS queue_ms,
    CASE
        WHEN queued_overload_time + queued_provisioning_time + queued_repair_time
             > execution_time
            THEN 'QUEUE. Scale out (multi-cluster). A larger warehouse does not add a lane.'
        ELSE 'EXECUTION. Open the profile before changing the warehouse.'
    END AS next_step
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
WHERE query_id = $slow_query_id;

-- ------------------------------------------------------------------ 5. Profile: widest operator, rows in, rows out
-- Snowsight: Admin -> Query History -> this query id -> Query Profile.
-- GET_QUERY_OPERATOR_STATS is the same tree. input_rows and output_rows are the probe.
ALTER SESSION SET QUERY_TAG = 'perflab_10_profile';
SELECT
    operator_id,
    operator_type,
    operator_statistics:input_rows::NUMBER AS rows_in,
    operator_statistics:output_rows::NUMBER AS rows_out,
    operator_statistics:output_rows::NUMBER
        / NULLIF(operator_statistics:input_rows::NUMBER, 0) AS out_per_in,
    operator_statistics:spilling:bytes_spilled_local_storage::NUMBER AS spill_local_bytes,
    operator_statistics:spilling:bytes_spilled_remote_storage::NUMBER AS spill_remote_bytes
FROM TABLE(GET_QUERY_OPERATOR_STATS($slow_query_id))
ORDER BY rows_out DESC NULLS LAST;

-- Join operators only. out_per_in above 1 is a fan-out. Lab 04 brings a real SCD2
-- join back to a multiplier of 1 with the effective-date predicate.
SELECT
    operator_type,
    operator_statistics:input_rows::NUMBER AS rows_in,
    operator_statistics:output_rows::NUMBER AS rows_out,
    operator_statistics:output_rows::NUMBER
        / NULLIF(operator_statistics:input_rows::NUMBER, 0) AS out_per_in
FROM TABLE(GET_QUERY_OPERATOR_STATS($slow_query_id))
WHERE operator_type ILIKE '%Join%'
ORDER BY out_per_in DESC NULLS LAST;

-- ------------------------------------------------------------------ 6. Classify pruning, spill, join, scale up, scale out
-- Pruning and spill are query-level facts. The join multiplier is an operator fact.
-- Read the first matching branch only: a queued query is not a pruning problem.
SELECT
    h.query_id,
    h.partitions_scanned,
    h.partitions_total,
    h.bytes_spilled_to_local_storage + h.bytes_spilled_to_remote_storage AS spill_bytes,
    h.queued_overload_time + h.queued_provisioning_time + h.queued_repair_time AS queue_ms,
    h.execution_time AS execution_ms,
    j.out_per_in AS widest_join_multiplier,
    CASE
        WHEN h.queued_overload_time + h.queued_provisioning_time + h.queued_repair_time
             > h.execution_time
            THEN 'Scale out. Multi-cluster (lab 09). Scale up makes each waiter faster and leaves the queue.'
        WHEN h.bytes_spilled_to_local_storage + h.bytes_spilled_to_remote_storage > 0
            THEN 'Spill. Rewrite the sort, window, or hash (lab 03). Scale up only if the rewritten query still spills.'
        WHEN h.partitions_total > 0
             AND h.partitions_scanned = h.partitions_total
            THEN 'No pruning. A selective filter still read every micro-partition (labs 02 and 06).'
        WHEN j.out_per_in > 1
            THEN 'Join fan-out. Rows out exceeded rows in. Fix the grain (lab 04) before adding credits.'
        ELSE 'Scale up. The query ran, pruned or had no partitions to prune, did not spill, and did not fan out (lab 03).'
    END AS classification
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200)) h
LEFT JOIN (
    SELECT MAX(
               operator_statistics:output_rows::NUMBER
               / NULLIF(operator_statistics:input_rows::NUMBER, 0)
           ) AS out_per_in
    FROM TABLE(GET_QUERY_OPERATOR_STATS($slow_query_id))
    WHERE operator_type ILIKE '%Join%'
) j
    ON TRUE
WHERE h.query_id = $slow_query_id;

-- Generator probes have no base-table partitions, and this join is small enough that
-- spill_bytes may be 0. Those are real readings. Labs 02, 03 and 06 move the numbers
-- on TXN_SORTED. The classification above is the one you re-run after those labs.

-- ------------------------------------------------------------------ 7. Rerun, cache still off, then compare
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'perflab_10_slow_rerun';
SELECT COUNT(*) AS slow_rows_rerun
FROM (
    SELECT SEQ4() AS id
    FROM TABLE(GENERATOR(ROWCOUNT => 200000))
) ones
JOIN (
    SELECT SEQ4() AS id
    FROM TABLE(GENERATOR(ROWCOUNT => 10))
) tens
    ON TRUE;

SELECT
    query_tag,
    total_elapsed_time AS elapsed_ms,
    execution_time AS execution_ms,
    queued_overload_time + queued_provisioning_time + queued_repair_time AS queue_ms,
    partitions_scanned,
    partitions_total,
    bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage AS spill_bytes,
    rows_produced
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
WHERE query_tag IN ('perflab_10_fast', 'perflab_10_slow', 'perflab_10_slow_rerun')
  AND query_type = 'SELECT'
ORDER BY total_elapsed_time DESC;

-- Recent selects on this warehouse, slowest first, when you are triaging someone else's query.
SELECT
    query_id,
    query_tag,
    user_name,
    warehouse_size,
    total_elapsed_time AS elapsed_ms,
    execution_time AS execution_ms,
    queued_overload_time AS queued_overload_ms,
    partitions_scanned,
    partitions_total,
    bytes_spilled_to_local_storage AS spill_local_bytes
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 100))
WHERE query_type = 'SELECT'
  AND start_time >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC;

EXECUTE IMMEDIATE $$
DECLARE
    present INTEGER;
BEGIN
    SELECT COUNT(*) INTO :present
    FROM MERIDIAN_RAW.INFORMATION_SCHEMA.TABLES
    WHERE table_schema = 'PERF_LAB'
      AND table_name = 'TXN_SORTED';
    IF (present = 0) THEN
        RETURN 'TXN_SORTED is not built. Pruning is labs 02 and 06. Spill and scale up are lab 03. Scale out is lab 09.';
    END IF;
    RETURN 'TXN_SORTED exists. Re-read QUERY_HISTORY for tags perflab_02, perflab_03, perflab_06 and perflab_09 with the classification above.';
END;
$$;
