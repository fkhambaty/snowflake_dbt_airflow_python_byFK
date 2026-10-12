# How a data architecture is designed

This is the order of the first episode. Requirements come before a tool. Each step
produces one standard artifact. The next step is not allowed to start until that
artifact exists, because that is how a design review actually works.

The standards below are the ones a design review expects. Two larger frameworks are
worth being able to name, and worth not performing:

* **DAMA-DMBOK** defines Data Architecture as a knowledge area: requirements, enterprise
  data model, data flows, and the lineage from business term to physical column. The
  steps below are that knowledge area, written as documents instead of as a poster.
* **TOGAF** and the **Zachman grid** are architecture frameworks for a whole enterprise.
  Useful vocabulary (viewpoints, baseline vs target). A full ADM cycle or a filled
  Zachman matrix for one analytics platform is ceremony. Say that out loud if someone
  asks why it is not in the folder.

ANSI/SPARC (1975) is the standard that still structures the data model: a **conceptual**
schema the business recognises, a **logical** schema independent of the engine, and a
**physical** schema that is the engine. C4 (c4model.com) is the standard for the system
pictures around that model.

## The sequence

| Step | Question this step answers | Artifact | Standard | File |
|---|---|---|---|---|
| 1. Requirements | What must be true, in numbers? | Requirements catalogue: business questions and NFRs, each with a measure and a consequence | DAMA data requirements | [`DESIGN_DOC.md`](DESIGN_DOC.md) §2 |
| 2. Context | What is inside the platform, and what stays outside? | System context diagram | C4, level 1 | [`diagrams/01_context.mmd`](diagrams/01_context.mmd) |
| 3. Conceptual model | Which business things exist, and how do they relate? No keys, no database. | Conceptual ER | ANSI/SPARC conceptual schema | [`diagrams/03_conceptual.mmd`](diagrams/03_conceptual.mmd) |
| 4. Logical model | What is one row, which dimensions are shared, which history is kept? | Bus matrix and logical star | Kimball enterprise bus | [`BUS_MATRIX.md`](../07_data_modelling/BUS_MATRIX.md), [`star_schema.mmd`](../07_data_modelling/star_schema.mmd) |
| 5. Data flow | How does one change travel, and how stale may it be? | Container diagram and a flow for one transaction | C4 level 2, and a data-flow diagram | [`diagrams/02_container.mmd`](diagrams/02_container.mmd), [`diagrams/04_data_flow.mmd`](diagrams/04_data_flow.mmd) |
| 6. Decisions | Why this and not the alternative? | One ADR per hard-to-reverse choice, including the rejected option and the trigger to revisit | Nygard ADR | [`adr/`](adr/) |
| 7. Physical model | Types, clustering, incremental strategy, grants, search access path | The dbt project. A second DDL maintained by hand will drift, so the models are the physical model. | ANSI/SPARC internal schema | `04_dbt_meridian_dw/` |
| 8. Security viewpoint | Who may see which row and which column? | Entitlements, row access policies, tags. Not a copy of the data model. | Same tables, a different viewpoint | `03_snowflake/06_row_level_security.sql`, ADR 0006 |
| 9. Capacity | What does the chosen freshness cost per month? | Arithmetic in the design doc, before the build | Design doc §4 | [`DESIGN_DOC.md`](DESIGN_DOC.md) §4 |
| 10. Operability and recovery | How will we detect failure, recover safely, and prove the targets? | SLO views, runbooks and timed recovery exercise | Operational readiness review | [`OPERATIONS_RUNBOOK.md`](OPERATIONS_RUNBOOK.md), [`DR_RUNBOOK.md`](DR_RUNBOOK.md) |

## Rules for the diagrams

* A context diagram names people and external systems. It does not name Snowflake, dbt or Parquet. If a tool name appears, it has fallen to level 2.
* A container diagram names deployable pieces and stores. It does not name columns.
* A conceptual model names business entities. `transaction_id VARCHAR` does not belong on it.
* The logical model is where grain, conformed dimensions and SCD type are decided. The bus matrix is that model in one page.
* The physical model is allowed to add things the business did not ask for, when a measurement requires them. `omni_search` is one of those: it is not a business process, so it is not a row on the bus matrix. It is a serving structure. ADR 0009.

## Where "why this and not that" is allowed to live

Not in a slide of logos. In an ADR, written when the decision is made:

| Decision | Chosen | Rejected, and why it lost |
|---|---|---|
| [0001](adr/0001-watermark-cdc-before-log-based.md) | Watermark CDC | Log-based CDC: correct, heavier than the first release can operate |
| [0002](adr/0002-append-only-variant-raw.md) | Append-only VARIANT raw | Typed raw: a new column breaks the load |
| [0003](adr/0003-kimball-for-the-presentation-layer.md) | Kimball stars | Data Vault, one big table |
| [0004](adr/0004-dbt-plus-airflow.md) | dbt + Airflow | Dynamic Tables alone, Tasks, Cosmos |
| [0005](adr/0005-model-scores-land-in-the-warehouse.md) | Scores land in the warehouse | Writing scores back into Postgres |
| [0006](adr/0006-row-access-by-user-entitlements-owned-by-security.md) | Row policies on the user | A filter in the app, one view per persona |
| [0007](adr/0007-open-table-formats-deferred.md) | Snowflake-native tables for now | Iceberg on day one |
| [0008](adr/0008-one-owner-per-object-type.md) | Terraform / dbt / security, one owner each | Two tools managing one grant |
| [0009](adr/0009-omni-search-is-a-serving-index.md) | Identifier index + substring Search Optimization | A full scan, or a second search engine |
| [0010](adr/0010-contracts-at-public-boundaries.md) | Contracts on stable public marts | Contract every private staging model, or contract nothing |

## What you say in the first ten minutes

1. Read the business asks and the NFR table. Point at one number (15-minute freshness) and one consequence (the resource monitor stops the warehouse).
2. Show the context diagram. "Core banking stays the system of record. We only read changes."
3. Show the conceptual model. "No database yet. If the business does not recognise this picture, the star schema underneath it is wrong."
4. Show the bus matrix. Declare one grain out loud.
5. Show the flow of a single transaction.
6. Open one ADR, including the alternative you rejected. ADR 0005 or 0009 both work on camera.
7. Only then open a SQL file.
