# Architecture Decision Records

An ADR records one significant decision that is hard to reverse: the context, the options
considered, the choice, and what it costs. It is written when the decision is made and is
never edited afterwards. If the decision changes, a new ADR supersedes it.

Why bother: in six months nobody remembers why raw is VARIANT. Without the record, the
next engineer "fixes" it and reintroduces the problem it solved. In an interview, "here is
the ADR, here is the alternative I rejected and why" is what separates an architect from
someone who followed a tutorial.

Format (Michael Nygard, 2011): **Status · Context · Decision · Alternatives · Consequences · Revisit when.**

| # | Title | Status |
|---|---|---|
| 0001 | [Watermark CDC first, log-based CDC as the upgrade path](0001-watermark-cdc-before-log-based.md) | Accepted |
| 0002 | [Raw is append-only VARIANT](0002-append-only-variant-raw.md) | Accepted |
| 0003 | [Kimball star schemas for the presentation layer](0003-kimball-for-the-presentation-layer.md) | Accepted |
| 0004 | [dbt for transformation, Airflow for orchestration](0004-dbt-plus-airflow.md) | Accepted |
| 0005 | [Model scores land in the warehouse, never in the OLTP](0005-model-scores-land-in-the-warehouse.md) | Accepted |
| 0006 | [Row access keyed on the user; entitlements owned by security](0006-row-access-by-user-entitlements-owned-by-security.md) | Accepted |
| 0007 | [Open table formats (Iceberg) deferred](0007-open-table-formats-deferred.md) | Accepted |
| 0008 | [One owner per object type: Terraform, dbt, security SQL](0008-one-owner-per-object-type.md) | Accepted |
| 0009 | [Omni search is a serving index, not a second search engine](0009-omni-search-is-a-serving-index.md) | Accepted |
| 0010 | [Contracts belong at public boundaries](0010-contracts-at-public-boundaries.md) | Accepted |
| 0011 | [Shared tables with a row-access policy; physical isolation only when a tenant requires it](0011-multitenancy-patterns.md) | Accepted |
