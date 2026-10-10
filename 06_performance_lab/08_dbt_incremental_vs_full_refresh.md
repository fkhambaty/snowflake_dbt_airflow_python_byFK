# Experiment 08 — dbt: full refresh vs incremental, measured

**Claim to prove:** rebuilding `fct_transactions` from scratch every 5 minutes is 20–100× more
expensive than merging only the new/changed rows, and the gap widens every day.

## Set-up

```bash
cd 04_dbt_meridian_dw
export DBT_PROFILES_DIR=.          # or ~/.dbt
```

Make sure the simulator has been running for a while so there is a real delta.

## Run 1 — full refresh (the trap)

```bash
time dbt run --select fct_transactions --full-refresh --target prod
```

dbt prints `[CREATE TABLE AS ... in 48.2s]`. Note the time. In Snowflake:

```sql
SELECT query_text, total_elapsed_time/1000 AS s, round(bytes_scanned/1048576) AS mb,
       bytes_spilled_to_local_storage
FROM TABLE(MERIDIAN_ANALYTICS.INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 50))
WHERE query_tag = 'dbt_prod' AND query_text ILIKE '%fct_transactions%'
ORDER BY start_time DESC;
```

## Run 2 — incremental (normal operation)

```bash
time dbt run --select fct_transactions --target prod
```

dbt prints `[MERGE ... in 3.1s]` (only the rows whose `_extracted_at` is inside the
lookback window are touched). Look at the generated SQL in `target/run/.../fct_transactions.sql`:
a `create temporary table ... as (select ... where _extracted_at > ...)` followed by a `merge into`.

## Run 3 — show the wrong incremental filter

Temporarily change the incremental filter in `fct_transactions.sql` from `_extracted_at` to
`transaction_ts` and run again. Explain why: a PENDING→POSTED update has an OLD `transaction_ts`
and would be missed. The reconciliation test fails. Change it back.

## Run 4 — the lookback window trade-off

Change `incremental_lookback_hours` in `dbt_project.yml` to 48 and re-run. Time goes up because the
MERGE touches more rows. Then set it to 0 and explain the race you just opened (a batch that lands
while dbt is reading could be skipped). 2 hours is a comfortable default for a 5-minute cadence.

## What to say on camera

- Incremental models trade **correctness risk** (late data, deletes, schema change) for **cost**.
  Every risk has a mitigation in this project: lookback window, hard-delete post-hook,
  `on_schema_change: append_new_columns`, and a nightly reconciliation test.
- `--full-refresh` is not evil: run it after a bug fix or a logic change, from the daily DAG,
  on a bigger warehouse, once.
- Record both timings in a table on screen. The numbers are the lesson.

| run | statement | seconds | MB scanned | credits (XS) |
|---|---|---|---|---|
| full refresh | CREATE TABLE AS | | | |
| incremental | MERGE | | | |
