-- =====================================================================================
--  EXPERIMENT 01 (Postgres): the CDC extraction query without an index
--
--  The ingestion job runs this every 5 minutes:
--     SELECT * FROM core.transactions WHERE updated_at > :wm AND updated_at <= :high
--  With no index on updated_at Postgres reads the WHOLE table every 5 minutes.
--  On 5M rows that is ~1-3 s; on 20M rows 10+ s of pure I/O, 288 times a day, for ~2k rows.
-- =====================================================================================
-- Execute each statement in DBeaver, connected to meridian_core.

-- Make sure the planner statistics are fresh so the comparison is fair
ANALYZE core.transactions;

-- BEFORE ----------------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT *
FROM core.transactions
WHERE updated_at > now() - interval '5 minutes'
  AND updated_at <= now() - interval '10 seconds'
ORDER BY updated_at;
-- Expect:  "Seq Scan on transactions ... Rows Removed by Filter: 4,99x,xxx"
--          Buffers: shared hit=... read=...   Execution Time: 1500-4000 ms

-- FIX -------------------------------------------------------------------------------------
-- CONCURRENTLY: no write lock on a live OLTP table (cannot run inside a transaction block)
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_transactions_updated_at ON core.transactions (updated_at);

-- AFTER -----------------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT *
FROM core.transactions
WHERE updated_at > now() - interval '5 minutes'
  AND updated_at <= now() - interval '10 seconds'
ORDER BY updated_at;
-- Expect:  "Index Scan using ix_transactions_updated_at"   Execution Time: 1-20 ms

-- BONUS: the statement query (account + time range) --------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM core.transactions
WHERE account_id = 4242 AND transaction_ts >= now() - interval '90 days'
ORDER BY transaction_ts DESC;
-- Seq scan again. Composite index, most selective column first, sort column second:
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_transactions_account_ts ON core.transactions (account_id, transaction_ts DESC);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM core.transactions
WHERE account_id = 4242 AND transaction_ts >= now() - interval '90 days'
ORDER BY transaction_ts DESC;
-- Index Scan, no Sort node (the index already delivers the order).

-- Talking points for the video --------------------------------------------------------------
--  * Why not index everything? Each index slows every INSERT/UPDATE (write amplification) and
--    costs storage. core.transactions gets thousands of writes per minute.
--  * Index size:  SELECT pg_size_pretty(pg_relation_size('core.ix_transactions_updated_at'));
--  * Index usage: SELECT * FROM pg_stat_user_indexes WHERE relname = 'transactions';
--  * In production the index would have been there from day one; the lab removes it so the
--    plan difference is visible. The same reasoning applies to Snowflake clustering (02).
