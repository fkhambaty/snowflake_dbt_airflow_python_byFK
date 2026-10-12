# Disaster recovery and continuity

This project proves **logical recovery inside one Snowflake account**. It does not claim
cross-region disaster recovery: database replication and failover groups need a second
account/region and an edition that the course trial does not validate.

## Targets

| Layer | RPO | RTO | Recovery source |
|---|---:|---:|---|
| Raw | one completed micro-batch | 1 hour | Postgres + watermark replay; raw has 7-day Time Travel |
| Marts | one daily successful build | 4 hours | append-only raw + dbt manifest/code |
| Entitlements/policies | last reviewed security script | 1 hour after marts | `06_row_level_security.sql` + `apply_governance_all` |
| ML scores | last passing model run | 4 hours | `MODEL_RUNS`; marts ignore rejected runs |

These are design targets until the exercises are timed on the connected Snowflake account.

## Recovery order

1. Stop writers (Airflow DAGs and ad-hoc dbt jobs).
2. Preserve evidence: failed query id, load batch id, `run_results.json`, current grants
   and policy attachments.
3. Decide whether this is lost source data, corrupt derived data, or an access-control issue.
4. Recover raw first. Use bounded replay; never reset all watermarks.
5. Rebuild the smallest dbt selection that restores the consumer.
6. Re-attach governance and run reconciliation.
7. Resume writers; record actual RPO/RTO and the cause.

## Monthly exercise

Run `03_snowflake/10_dr_exercises.sql`:

* inspect a table before a bad statement;
* swap a verified zero-copy clone into place;
* recover a dropped table with `UNDROP`;
* state the commands that rebuild marts from raw.

Record start/end timestamps and whether the result reconciled. A drill that was not timed
is documentation, not evidence.

## Region/account loss (explain-only)

A production bank would replicate critical databases to a paired account/region, replicate
the artifact/config repository separately, test role/grant recreation, and use a failover
group with a rehearsed DNS/client cutover. Raw Postgres also needs its own multi-AZ and
cross-region recovery. None of that is silently implied by Snowflake Time Travel.
