-- =====================================================================================
--  EXPERIMENT 09 (Snowflake): size vs concurrency
--
--  "Make the warehouse bigger" is the wrong fix when the problem is MANY small queries
--  waiting in line (dashboards at 9 am). Bigger = each query faster. Multi-cluster = more
--  queries at the same time. Queueing shows up as queued_overload_time in QUERY_HISTORY.
-- =====================================================================================
USE ROLE ACCOUNTADMIN;

-- ------------------------------------------------------------------ create the queue
-- Run this script from 2-3 Snowsight tabs at once, or use the Python snippet at the bottom.
USE WAREHOUSE WH_BI_XS;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'perflab_09_single_cluster';
SELECT branch_id, transaction_date, sum(amount)
FROM MERIDIAN_RAW.PERF_LAB.TXN_SORTED
WHERE transaction_date >= dateadd('day', -60, current_date())
GROUP BY 1, 2;

-- after the burst
SELECT query_tag, count(*) AS queries,
       round(avg(total_elapsed_time)) AS avg_ms,
       round(avg(queued_overload_time)) AS avg_queued_ms,
       max(queued_overload_time) AS max_queued_ms
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE('WH_BI_XS', RESULT_LIMIT => 500))
WHERE query_tag LIKE 'perflab_09%'
GROUP BY 1;

-- ------------------------------------------------------------------ fix: multi-cluster (Enterprise)
ALTER WAREHOUSE WH_BI_XS SET
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 3
  SCALING_POLICY = 'STANDARD';      -- STANDARD = start a cluster as soon as a query queues; ECONOMY waits ~6 min

ALTER SESSION SET QUERY_TAG = 'perflab_09_multi_cluster';
-- repeat the same burst -> avg_queued_ms collapses, avg_ms per query is unchanged (same size!)

-- ------------------------------------------------------------------ contrast: bigger size, single cluster
ALTER WAREHOUSE WH_BI_XS SET MAX_CLUSTER_COUNT = 1, WAREHOUSE_SIZE = MEDIUM;
ALTER SESSION SET QUERY_TAG = 'perflab_09_medium_single';
-- repeat the burst -> each query faster, but queueing returns once > 8 run at once.

-- ------------------------------------------------------------------ reset
ALTER WAREHOUSE WH_BI_XS SET WAREHOUSE_SIZE = XSMALL, MAX_CLUSTER_COUNT = 1;

/* Python burst generator (run from 02_ingestion_python with the same .env):

import threading
from pg_to_snowflake import sf_connect
SQL = """SELECT branch_id, transaction_date, sum(amount) FROM MERIDIAN_RAW.PERF_LAB.TXN_SORTED
         WHERE transaction_date >= dateadd('day', -60, current_date()) GROUP BY 1, 2"""
def one():
    c = sf_connect(); cur = c.cursor()
    cur.execute("ALTER SESSION SET USE_CACHED_RESULT = FALSE")
    cur.execute("ALTER SESSION SET QUERY_TAG = 'perflab_09_burst'")
    cur.execute("USE WAREHOUSE WH_BI_XS"); cur.execute(SQL); cur.fetchall(); c.close()
threads = [threading.Thread(target=one) for _ in range(20)]
[t.start() for t in threads]; [t.join() for t in threads]
*/
