-- =====================================================================================
--  Measurement harness. Tag every experiment query, then read the numbers back.
--  Rule: ALWAYS disable the result cache while benchmarking, otherwise the second run is a lie.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;     -- result cache off for honest timings
ALTER SESSION SET QUERY_TAG = 'perflab_02_before'; -- change before each experiment

-- ... run the experiment query ...

-- Read back one row per tagged query. INFORMATION_SCHEMA is instant; ACCOUNT_USAGE lags ~45 min.
SELECT query_tag,
       left(query_text, 80)                                    AS query,
       warehouse_size,
       total_elapsed_time                                      AS elapsed_ms,
       execution_time                                          AS exec_ms,
       round(bytes_scanned / 1024 / 1024)                      AS mb_scanned,
       partitions_scanned,
       partitions_total,
       round(100.0 * partitions_scanned / nullif(partitions_total, 0), 1) AS pct_partitions_scanned,
       round(bytes_spilled_to_local_storage / 1024 / 1024)     AS mb_spilled_local,
       round(bytes_spilled_to_remote_storage / 1024 / 1024)    AS mb_spilled_remote,
       rows_produced,
       queued_overload_time                                    AS queued_ms,
       start_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
WHERE query_tag LIKE 'perflab_%'
  AND query_type = 'SELECT'
ORDER BY start_time DESC;

-- Side-by-side comparison for one experiment (change the prefix)
WITH q AS (
  SELECT query_tag, total_elapsed_time, bytes_scanned, partitions_scanned, partitions_total,
         bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage AS spilled
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
  WHERE query_tag LIKE 'perflab_02_%' AND query_type = 'SELECT'
  QUALIFY row_number() OVER (PARTITION BY query_tag ORDER BY start_time DESC) = 1
)
SELECT query_tag, total_elapsed_time AS ms, round(bytes_scanned/1048576) AS mb,
       partitions_scanned || ' / ' || partitions_total AS partitions, round(spilled/1048576) AS mb_spilled
FROM q ORDER BY query_tag;

-- Clustering health of any table
-- SELECT SYSTEM$CLUSTERING_INFORMATION('MERIDIAN_RAW.PERF_LAB.TXN_RANDOM_ORDER', '(transaction_date)');
