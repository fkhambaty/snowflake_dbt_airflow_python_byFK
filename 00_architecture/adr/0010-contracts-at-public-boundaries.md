# 0010. Contracts at public boundaries; drift sentinels at raw boundaries

**Status:** Accepted

## Context
Raw is intentionally schemaless VARIANT. That lets a new optional source field land
without stopping ingestion, but it also lets a breaking rename land successfully and
turn into NULL in staging. At the other end, facts and dimensions are interfaces used by
policies, the semantic view, ML and dashboards.

## Decision

* Keep raw permissive. A warning-level test checks that recent transaction payloads still
  contain the keys staging requires.
* Enforce dbt contracts on public, high-blast-radius models: `dim_branch`,
  `dim_customer`, and `fct_transactions`.
* Continue to use data tests for content. A contract proves column names and types; it
  does not prove that an amount is sensible or a foreign key exists.
* Do not contract every private intermediate model. That would turn harmless refactors
  into interface migrations without protecting an external consumer.

## Alternatives

| Option | Why not |
|---|---|
| Contract every model | High maintenance and false coupling inside one dbt project. |
| Typed raw tables | A harmless additive source column can break `COPY`; rejected in ADR 0002. |
| Tests only | They run after materialization and cannot prevent a public column from being dropped or changing type. |
| Contracts only | A perfectly typed table can still contain duplicate keys, missing FX or wrong amounts. |

## Consequences

Breaking public changes fail before replacement. Additive raw changes continue to land.
A renamed required source key warns while the raw payload remains available for repair.
The owner must promote a genuinely new field through staging and the public contract in
the same reviewed change.

## Revisit when

The project is split into dbt Mesh domains. At that point contract every cross-project
`public` model and version breaking interfaces.
