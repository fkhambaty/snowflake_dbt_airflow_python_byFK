# Performance Lab — make it slow, measure, fix, measure again

Every experiment follows the same four beats so students see a **number**, not a claim:

1. **Break it** – run the naive version (or build the badly-shaped table).
2. **Measure** – `00_measure.sql` pulls elapsed ms, bytes scanned, partitions scanned/total,
   spill bytes from `QUERY_HISTORY` using a `QUERY_TAG` you set before each run.
3. **Fix it** – index / cluster / rewrite / resize.
4. **Measure again** – same query, same tag suffix `_after`. Put both rows side by side.

| # | File | Problem you create | Fix | Metric that moves |
|---|---|---|---|---|
| 01 | `01_postgres_missing_index.sql` | CDC extraction query seq-scans 5–20M rows | `CREATE INDEX CONCURRENTLY ... (updated_at)` | `EXPLAIN (ANALYZE, BUFFERS)` time: seconds → ms |
| 02 | `02_snowflake_pruning_clustering.sql` | 100M-row fact loaded in random order | insert `ORDER BY` / `CLUSTER BY` | partitions_scanned / partitions_total |
| 03 | `03_spilling_and_warehouse_size.sql` | huge sort/window on XS spills to disk | rewrite, then scale XS → M and compare | bytes_spilled_to_*_storage, elapsed |
| 04 | `04_join_explosion_scd2.sql` | SCD2 join without the date-range predicate | add `valid_from <= ts < valid_to` | row count (and the dbt singular test) |
| 05 | `05_caching_layers.sql` | "it was fast the second time" misleads you | `ALTER SESSION SET USE_CACHED_RESULT = FALSE`, suspend WH | elapsed with/without result cache & local disk cache |
| 06 | `06_predicate_antipatterns.sql` | `TO_DATE(ts) = ...`, `SELECT *`, `UNION`, `DISTINCT` | sargable range, named columns, `UNION ALL` | bytes_scanned, elapsed |
| 07 | `07_search_optimization_and_mv.sql` | point lookup by `reference_no`, then a fragment of that id (`CONTAINS`) | Equality SOS, then substring SOS; MV for an aggregate | elapsed, partitions_scanned |
| 08 | `08_dbt_incremental_vs_full_refresh.md` | `dbt run --full-refresh` on the fact every 5 min | incremental MERGE + lookback window | dbt run timing and credits |
| 09 | `09_warehouse_sizing_and_concurrency.sql` | 20 dashboard queries queue on one XS | multi-cluster vs bigger size | queued_overload_time |
| 10 | `10_slow_query_triage_playbook.sql` | A slow query with no order of attack | Cache off, then history ordered slow and fast, queue vs execution, profile rows in/out, then pruning / spill / join / scale-out vs scale-up | elapsed_ms, queue_ms, partitions, spill bytes, join out/in |

**Trial budget**: building the 100M-row lab table on an XS costs roughly 0.3–0.5 credits; the whole
lab stays well under 10 credits. Drop `MERIDIAN_RAW.PERF_LAB` when you are done.
