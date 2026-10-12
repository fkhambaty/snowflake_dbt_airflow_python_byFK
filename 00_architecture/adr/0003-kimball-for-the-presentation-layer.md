# 0003. Kimball star schemas for the presentation layer

**Status:** Accepted

## Context
Consumers are BI dashboards, a semantic view for plain-English questions, and ML feature
builds. One source system. A team of a few engineers.

## Decision
Kimball dimensional modelling. Conformed dimensions are shared across facts (see the bus
matrix). SCD2 is used where history matters (customer, account, branch). Facts are kept
at the atomic grain, and aggregates are built only where measured queries need them.

## Alternatives
| Option | When it wins | Why not here |
|---|---|---|
| Data Vault 2.0 | Many sources integrating the same business keys; strict auditability of every load | One source. Hubs, links and satellites add a layer that every query must undo. Raw VARIANT already gives auditability (ADR 0002). |
| One big table (OBT) | A single dashboard with fixed questions | SCD2 history and multiple facts produce either duplication or fan-out. Semantic tools need conformed dimensions. |
| Inmon 3NF EDW | Enterprise-wide integration first | Slower to first value. Dimensional marts on top are still required. |

## Consequences
* Business users and Cortex Analyst understand stars. The semantic view maps one-to-one.
* SCD2 point-in-time joins must use `valid_from <= ts < valid_to`. Otherwise you get the fan-out shown in perf lab 04.
* Adding a second core system (an acquired bank) means conforming its keys into existing dimensions. That is the moment to reconsider a vault-style integration layer *below* the stars.

## Revisit when
A second source system with overlapping customers arrives.
