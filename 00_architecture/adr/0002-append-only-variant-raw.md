# 0002. Raw is append-only VARIANT

**Status:** Accepted

## Context
Source schemas change without notice. We need to replay history after a bug in
transformation logic, and we need to prove to an auditor what the source said at a
point in time.

## Decision
Each raw table has a single `record VARIANT` column plus load metadata (`_extracted_at`,
`_batch_id`, `_source_file`). Rows are only ever inserted. Typing, deduplication and
renaming happen in dbt staging.

## Alternatives
| Option | Why not |
|---|---|
| Typed raw tables mirroring Postgres | A new source column breaks `COPY`. A type change silently truncates. |
| MERGE into raw (latest state only) | Destroys history. You cannot rebuild a mart as of last Tuesday. |
| Schema evolution on typed tables (`ENABLE_SCHEMA_EVOLUTION`) | Viable. It still mutates raw and hides changes. Kept as an option for very wide tables. |

## Consequences
* A new column costs nothing at load time. It appears in staging when someone chooses to expose it.
* Any mart can be rebuilt from raw (RPO of marts = raw).
* Raw grows forever. Mitigation: a retention policy after the regulatory period. Compressed storage is cheap (design doc §4).
* Every staging model must dedupe (`qualify row_number() ...`). That is the price of idempotent loads.

## Revisit when
A table is so wide or hot that VARIANT extraction dominates staging cost. Measure first.
