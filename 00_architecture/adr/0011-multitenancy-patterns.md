# 0011. Shared tables with a row-access policy; physical isolation only when a tenant requires it

**Status:** Accepted

## Context

Meridian is one bank with many countries and branches. A country manager must see only
that country's rows. A branch manager must see only that branch. The same dbt models,
semantic view and warehouse serve every country.

A `country_code` column, a customer id, or a UUID on the row names the tenant. It does
not decide who may read the row. Snowflake `PRIMARY KEY` and `FOREIGN KEY` constraints
are informational: they are not enforced, so a primary key on a tenant id does not stop
a second row and does not hide anyone else's rows. `NOT NULL` is enforced, so it can
require the tenant column to be present. Presence is still not authorization.

## Decision

* **Shared database, shared schema, shared tables.** One `dim_customer`, one
  `fct_transactions`, one dbt project, one contract.
* **Isolation is a row access policy** keyed on `CURRENT_USER()` and an entitlement
  row (`ADR 0006`, `03_snowflake/06_row_level_security.sql`). The country proof is
  `RAP_COUNTRY_SCOPE` on `country_code`. The Hong Kong user sees HK only. A user with
  the same role and no entitlement row sees zero rows.
* **The role is not the tenant boundary.** The Hong Kong officer, the Hong Kong staff
  member and the unentitled user share `MERIDIAN_COUNTRY_OFFICER`. Masking still hides
  contact fields from staff. The role is not granted `MERIDIAN_RAW`.
* **Branch personas stay on the existing branch and customer policies.** A country
  policy is not bolted onto those tables. One table accepts one row access policy.

## Options

| Pattern | Isolation | Versioning and change | Cost | Blast radius | When it wins |
|---|---|---|---|---|---|
| Shared tables + row access policy | Logical. One missed grant or a policy that returns TRUE opens every tenant. | One model, one release, one backfill. | One warehouse, shared cache, lowest credits. | A bad transform or a bad policy hits every country. | This bank. Same star schema everywhere. |
| Schema per tenant | Stronger than a policy, weaker than a database. A `USAGE` grant on the wrong schema crosses tenants. | The same model is built N times, or dynamic SQL loops schemas. Drift between schemas is the usual bug. | Still one database. Warehouses can be shared or split. | A schema-level grant mistake. A shared warehouse is still a noisy neighbor. | A tenant must not see another tenant's object names, and the model count stays small. |
| Database per tenant | Strongest object boundary. Replication, failover and key rotation can differ per tenant. | N databases, N grants, N dbt targets or a generator. A contract change is N releases. | N warehouses, or one warehouse with N result caches fighting. Highest credits. | An account-level mistake. A database mistake stays in that database. | Contractual physical isolation, a tenant-owned key, or a region the others must not share. |
| Tenant UUID (or `country_code`) filtered in the query | None. Any SQL that omits the predicate reads every tenant. | One model. | Lowest. | The whole table, via any client, including an LLM that drops the predicate. | Never as the control. Fine as the column the policy receives. |

## Why not a UUID as the control

A UUID identifies a row. It does not identify the caller. `WHERE tenant_id = ?` in an
application, a BI tool, or a prompt is the filter the caller can delete. The policy
runs for every query, including queries that never mention `country_code`. The
entitlement lives in `APP_USER`, which security owns. The column on the mart is only
the policy argument.

## Consequences

* One backfill, one test suite, one semantic view. Country and branch differences are
  data and entitlements.
* A transform bug is visible to every country. Integrity checks in
  `11_mart_integrity_and_quarantine.sql` and the dbt singular test cover the shared
  tables, because there is one copy to corrupt.
* Noisy-neighbor credits are a warehouse question (performance labs 03 and 09), not a
  reason to split the schema.
* Adding a country is an entitlement row and, for the country proof, rows whose
  `country_code` is that country. It is not a new database.

## Revisit when

A country contract requires its own encryption key, its own failover, or a guarantee
that no shared table exists. Then move that country to its own database and keep the
policy inside it. Do not replace the policy with a UUID predicate.
