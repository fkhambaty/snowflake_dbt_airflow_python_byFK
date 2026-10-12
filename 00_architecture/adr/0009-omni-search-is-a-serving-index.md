# 0009. Omni search is a serving index with substring Search Optimization

**Status:** Accepted

## Context
Operations and customers ask for one box: type part of a transaction id and get the
matches, wherever that identifier lives (the transaction, its reference number, the
account, the customer, the card authorization). The table is clustered by date, so a
`LIKE '%4821%'` reads every micro-partition. Five such queries, one per mart, would do
it five times.

## Decision
Build `omni_search`, one row per identifier, and add Snowflake **Search Optimization on
`SUBSTRING(search_text)`** once. The app and any worksheet run:

```sql
WHERE CONTAINS(search_text, :fragment)   -- fragment length >= 4, already uppercased
```

The row access policy on `customer_id` applies to this table, so the same fragment
returns different rows for the CEO and for a customer. Names, email and phone are not
in the index.

Transaction ids, reference numbers and authorization ids merge every 5 minutes.
Account and customer ids merge daily (`search_refresh_reference`). They change rarely,
and re-merging millions of them every 5 minutes is the cost we refused in the design doc.

## Alternatives
| Option | Why not |
|---|---|
| `LIKE '%x%'` on `fct_transactions` (and the other marts) | Full scan per query. Clustering on date cannot prune a contains-predicate. Equality Search Optimization does not accelerate it either. |
| Elasticsearch / OpenSearch beside Snowflake | A second store to secure, to keep in sync, and to put the same row policies on. Justified when search is full text across documents. It is not justified for identifiers we already hold. |
| Cortex Search (hybrid keyword + vector) | Right tool for "transactions that read like this sentence". Wrong tool for an id fragment, and it does not replace the row access policy. |
| One role per branch, or a filter inside the Streamlit app | Same rejection as ADR 0006. The worksheet must obey the same rule as the app. |

## Consequences
* A 4-character fragment of a numeric id matches many entities. The result shows `entity_type` and `match_on`, and orders an exact id before a longer id that merely contains the fragment. Say this on camera; it is the product behaviour, not a bug.
* `--full-refresh` drops the search access path. Re-run `03_snowflake/07_omni_search.sql`.
* Maintenance credits are proportional to rows merged after the initial build. Estimate with `SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS` before enabling it.
* A deleted transaction is removed from the index by `prune_omni_search_deletes`. Account and customer rows removed at source linger until the next daily merge replaces them only if the merge sees the new state; a hard-deleted account number can remain until a full rebuild. Acceptable at this volume; revisit if account closure must disappear from search the same day.

## Revisit when
Search must cover free text (transaction descriptions, notes), or the identifier volume makes the Snowflake search build more expensive than a dedicated search engine that can enforce the same entitlements.
