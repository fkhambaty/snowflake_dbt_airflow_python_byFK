# 0001. Watermark CDC first, log-based CDC as the upgrade path

**Status:** Accepted

## Context
Twenty Postgres tables must reach Snowflake within the 15-minute freshness NFR. We may
not modify the core banking application. We may add triggers and read replicas.

## Decision
Extract with a **high-watermark** query (`updated_at > last_watermark - overlap`) every
5 minutes, write Parquet, then `PUT` + `COPY INTO` an append-only raw table. Postgres
triggers maintain `updated_at` and write hard deletes to `cdc.deleted_records`.

## Alternatives
| Option | Why not now |
|---|---|
| Log-based CDC (Debezium → Kafka, or Snowflake's Openflow / Postgres connector) | Correct by construction (it captures every change, including deletes and trigger-bypassing updates). But it needs logical replication slots, a connector runtime, and someone on call for slot bloat. Too much to run before the first report ships. |
| Full reload nightly | Fails freshness. Cost grows with history, not with change. |
| Application-emitted events | Requires changing the core banking app, which is not allowed. |

## Consequences
* Simple, debuggable, and idempotent: re-running a window inserts duplicates that staging dedupes.
* **Misses** changes made with triggers disabled, and intermediate states between two polls.
  Reconciliation (`reconcile_with_pandas.py`) is the safety net.
* Polling load on the source. Index `updated_at` (the perf lab shows the cost without it).

## Revisit when
Freshness must drop below about a minute (real-time fraud blocking), or reconciliation
drift appears. The path is already prepared: `REPLICA IDENTITY FULL` is set in
`04_cdc_triggers.sql`, and raw tables keep the same shape, so staging does not change.
