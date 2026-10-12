# 0005. Model scores land in the warehouse, never in the OLTP

**Status:** Accepted (supersedes an earlier draft that wrote scores to `core.ml_scores` in Postgres)

## Context
The training job produces card-decision, propensity and fraud scores. An earlier design
wrote them back to Postgres, from where the extractor replicated them into Snowflake.

## Decision
Training reads **gold** features (`ml_customer_features`, `fct_card_applications`,
`fct_card_authorizations`) as role `MERIDIAN_ML`. It writes run metadata to
`MERIDIAN_RAW.ML.MODEL_RUNS` and scores to `MERIDIAN_RAW.ML.MODEL_SCORES`. dbt stages
only the latest run with status `SUCCEEDED` for each model, and scored marts read from there.

## Why the earlier design was wrong
1. **Analytical output in the system of record.** The OLTP becomes coupled to a model's
   release cycle, and its backups and DR now contain data the bank does not own operationally.
2. **A loop.** Warehouse → model → OLTP → extractor → warehouse. A five-minute lag at
   best, and a bad batch replicates before anyone sees it.
3. **Training/serving skew.** Features were recomputed in pandas from raw Postgres tables,
   while the marts computed them differently in SQL. Now one dbt model defines every
   feature for both training and scoring.

## Alternatives
| Option | Why not |
|---|---|
| Snowpark ML inside Snowflake | A good target. It keeps the same contract (`MODEL_RUNS`/`MODEL_SCORES`) and moves the compute. The course keeps local scikit-learn so it runs on a laptop. |
| Feature-store product | Overkill for one feature table. Revisit when online, sub-second serving is required. |

## Consequences
* A rejected model (holdout AUC below the gate) never reaches a mart. The last good scores stay.
* `MODEL_RUNS` records the features used, training rows, AUC and code version (lineage for model risk management).
* If the bank's card platform needs scores operationally, it should get them from an API
  or a reverse-ETL job with its own contract, not from a shared table.
