# Meridian operations runbook

This is a course system on synthetic data. The procedures are production-shaped; the
targets are not proven until a Snowflake-connected run records evidence in
`MERIDIAN_ANALYTICS.OPERATIONS.V_PLATFORM_STATUS`.

## Ownership and first response

| Signal | Target | First responder | Source of truth |
|---|---:|---|---|
| Hot-source freshness | ≤ 15 minutes | Data platform | `V_PIPELINE_HEALTH`, freshness DAG |
| Daily reconciliation | 0 mismatched groups | Analytics engineering | `RECONCILIATION_RUNS` |
| dbt error tests | 0 | Model owner | `DQ_FAILURES`, `run_results.json` |
| Monthly credits | < resource-monitor quota | Platform owner | `V_WAREHOUSE_CREDITS_DAILY` |
| Persona access | deny unmapped users | Security | `APP_USER`, `ACCESS_HISTORY` |

Roles and warehouses are Terraform-owned. Marts and their grants are dbt-owned.
Policies, tags and entitlements are security-owned. Do not repair one owner's object
with another tool.

## Daily check (five minutes)

```sql
select * from MERIDIAN_ANALYTICS.OPERATIONS.V_PLATFORM_STATUS
order by status, signal_type, signal_name;

select * from MERIDIAN_RAW.CONTROL.V_FAILED_LOADS_24H
order by started_at desc;
```

Then check the latest Airflow runs for `meridian_microbatch_ingest`,
`meridian_source_freshness`, and `meridian_daily_batch`. A green DAG with a red
platform-status row is an incident; orchestration success is not data success.

## Incident: a hot source is stale

1. Check whether Postgres is reachable and whether the Airflow extraction task failed.
2. Read `LOAD_LOG.error_message`; do not reset the watermark.
3. Retry the failed mapped task. Raw is append-only and staging dedupes, so retry is safe.
4. If a known time window was missed, trigger `meridian_bounded_replay` with one table,
   `since`, and `until`. Replay does **not** move normal forward progress.
5. Run `dbt build --selector microbatch`, then `assert_pipeline_health`.
6. If reconciliation still fails, preserve the raw batch and open a data incident.

Do not use Airflow `catchup=True`: it would define a second set of windows that competes
with the source watermark.

## Incident: COPY rejects a file

The main path uses `ON_ERROR=ABORT_STATEMENT`: no partial batch and no watermark advance.

1. Download or retain the Parquet part named in the task log.
2. Run `COPY ... VALIDATION_MODE=RETURN_ALL_ERRORS` against the stage.
3. Decide whether this is corrupt data or schema evolution. Never change the raw type to
   make one bad row load.
4. For an additive source field, raw VARIANT needs no change. Promote it through staging.
5. For a renamed required key, the drift sentinel warns. Coordinate a source contract
   change, replay the affected window, and only then update the public contract.

## Incident: reconciliation fails

Reconciliation is not freshness or a dbt test. Freshness checks arrival time; dbt tests
check rules inside the warehouse. Reconciliation compares source and warehouse truth
after the two-minute fair cutoff, by UTC date plus currency or branch. A run passes only
when every group has exact row-count equality and the absolute POSTED-amount difference
is below one cent.

1. Query the latest `RECONCILIATION_RUNS.details`.
2. Separate today's expected pipeline lag from an old mismatch.
3. Compare raw/staging/fact counts for the failing date and group.
4. Look for a status update that arrived after its event time. Incremental filters use
   `_extracted_at`, not `transaction_ts`.
5. Look for an SCD2 fan-out (`valid_from <= event_ts < valid_to`) or missing FX.
6. Repair code, run a bounded replay if raw is missing, then rebuild the affected selector.
7. Never edit a fact total by hand.

## Incident: a bad dbt release

1. Stop the daily DAG; the last good raw data is unchanged.
2. Use `QUERY_HISTORY` and dbt `run_results.json` to identify the first failing node.
3. For a shape change, restore the contract and deploy.
4. For wrong data written into a table, use Time Travel or a zero-copy pre-deploy clone
   to inspect the prior state; rebuild from append-only raw after the fix.
5. Re-run `dbt build --select <model>+`, reconciliation, and governance attachment checks.
6. Resume the DAG only when all three pass.

## Incident: persona sees too much or nothing

1. Confirm the person logged in as the intended Snowflake user; `USE ROLE` does not change
   `CURRENT_USER()`.
2. Query `GOVERNANCE.V_MY_SCOPE` and `APP_USER`.
3. Verify the app is owned by `MERIDIAN_APP`, never `MERIDIAN_TRANSFORMER`.
4. Inspect policy attachments with `POLICY_REFERENCES`.
5. Run `dbt run-operation apply_governance_all --target prod` after a rebuild.
6. Search `ACCESS_HISTORY` for the user and affected object.

Unmapped app users must see zero rows. Do not add them to an engineering bypass role as
a quick fix.

## Incident: credits are draining

1. The resource monitor suspends at 90% and immediately at 100%; do not raise the quota first.
2. Query `V_QUERY_COST_ATTRIBUTION` by workload and dbt node. Per-query credits are an
   allocation estimate; warehouse daily credits are authoritative.
3. Check repeated five-minute work, warehouse auto-suspend, full refreshes, Search
   Optimization maintenance, materialized views, and multi-cluster settings.
4. Cancel the query or suspend the affected warehouse.
5. Fix the workload, estimate the new monthly cost, and record a new ADR if the architecture changes.

## Recovery exercises

Run `03_snowflake/10_dr_exercises.sql` in a disposable schema each month:

* recover a dropped table with `UNDROP`;
* query a bad table before a statement with Time Travel;
* swap in a verified clone;
* rebuild a mart from raw.

The trial does not prove cross-region database replication or failover groups. Those
remain a design discussion, not a résumé claim.
