-- =====================================================================================
--  EXPERIMENT 02 (Snowflake): micro-partition pruning and clustering
--
--  Snowflake has no indexes. It keeps min/max metadata per ~16MB micro-partition and skips
--  ("prunes") partitions whose range cannot match your filter. Pruning only works if data
--  that is queried together is STORED together. Load in random order -> every partition
--  contains every date -> nothing can be skipped.
--
--  We generate 100M synthetic transactions directly in Snowflake (GENERATOR) so the effect is
--  unmistakable on a trial account. ~2-4 minutes on XS.
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE SCHEMA MERIDIAN_RAW.PERF_LAB;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- ------------------------------------------------------------------ build: RANDOM order (the trap)
CREATE OR REPLACE TABLE TXN_RANDOM_ORDER AS
SELECT
    seq8()                                                       AS transaction_id,
    uniform(1, 300000, random())                                 AS account_id,
    dateadd('second', -uniform(0, 540*86400, random()), current_timestamp())::timestamp_ntz AS transaction_ts,
    NULL::date                                                   AS transaction_date,
    (ARRAY_CONSTRUCT('DEPOSIT','WITHDRAWAL','CARD_PAYMENT','TRANSFER_OUT','TRANSFER_IN','FEE'))[uniform(0,5,random())]::string AS transaction_type,
    round(uniform(5, 5000, random()) * uniform(0.1, 1.0, random()), 2) AS amount,
    (ARRAY_CONSTRUCT('INR','AED','GBP','USD','SGD'))[uniform(0,4,random())]::string AS currency_code,
    uniform(1, 520, random())                                    AS branch_id,
    randstr(16, random())                                        AS reference_no
FROM TABLE(GENERATOR(ROWCOUNT => 100000000));
UPDATE TXN_RANDOM_ORDER SET transaction_date = to_date(transaction_ts);

-- ------------------------------------------------------------------ build: SORTED on load (the fix, variant A)
CREATE OR REPLACE TABLE TXN_SORTED AS
SELECT * FROM TXN_RANDOM_ORDER ORDER BY transaction_date, branch_id;

-- ------------------------------------------------------------------ how bad is it?
SELECT SYSTEM$CLUSTERING_INFORMATION('TXN_RANDOM_ORDER', '(transaction_date)');
--  average_overlaps / average_depth in the hundreds = terrible. total_partition_count ≈ 1,500+
SELECT SYSTEM$CLUSTERING_INFORMATION('TXN_SORTED', '(transaction_date)');
--  average_depth ≈ 1-2 = ideal.

-- ------------------------------------------------------------------ measure: same query, both tables
ALTER SESSION SET QUERY_TAG = 'perflab_02_random';
SELECT branch_id, count(*), sum(amount)
FROM TXN_RANDOM_ORDER
WHERE transaction_date BETWEEN dateadd('day', -7, current_date()) AND current_date()
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

ALTER SESSION SET QUERY_TAG = 'perflab_02_sorted';
SELECT branch_id, count(*), sum(amount)
FROM TXN_SORTED
WHERE transaction_date BETWEEN dateadd('day', -7, current_date()) AND current_date()
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

-- Now run the comparison block in 00_measure.sql with prefix perflab_02_
--  random : partitions_scanned ≈ partitions_total (100%), several GB scanned, 10-30 s on XS
--  sorted : partitions_scanned ≈ 1-2 % , tens of MB,  < 1 s
-- Open Query Profile in Snowsight: "Partitions scanned" vs "Partitions total" is the money shot.

-- ------------------------------------------------------------------ fix, variant B: automatic clustering
-- For a table that keeps receiving appends (our fct_transactions) a clustering key lets Snowflake
-- re-sort in the background. It costs credits -> only for large tables with a stable filter pattern.
ALTER TABLE TXN_RANDOM_ORDER CLUSTER BY (transaction_date);
-- Reclustering is asynchronous; check progress:
SELECT * FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(DATE_RANGE_START => dateadd('hour', -1, current_timestamp())));
-- After it finishes, re-run the perflab_02_random query -> same numbers as sorted.

-- ------------------------------------------------------------------ what dbt does for us
-- fct_transactions has  cluster_by=['transaction_date']  in its config. dbt-snowflake adds
-- ORDER BY transaction_date to every incremental insert and ALTER TABLE ... CLUSTER BY on create.
-- That is why the perf lab table is "random" and the production fact is not.

-- Cleanup when done:  DROP TABLE TXN_RANDOM_ORDER; DROP TABLE TXN_SORTED;
