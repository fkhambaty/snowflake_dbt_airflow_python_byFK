# Meridian Bank Analytics Platform: Design Document

| | |
|---|---|
| Status | Accepted (v1). Revisit after the first production quarter. |
| Author | Platform data architect |
| Reviewers | Head of Risk, CISO delegate, Finance BI lead, Card product owner |
| Decision log | [`adr/`](adr/) (one file per significant, hard-to-reverse choice) |

> Write this document **before** writing code. An architect is hired to make trade-offs
> visible and defensible. The code is the cheap part.
>
> The order to write it, and which diagram belongs to which step, is
> [`ARCHITECTURE_PROCESS.md`](ARCHITECTURE_PROCESS.md). That file is the first episode.

---

## 1. Problem

Meridian has 520 branches in several countries and currencies. Every report is built from
the core banking database, and every report disagrees with the next one. Card decisions
take two days. Fraud is found on the monthly statement, after the customer has already
complained.

**Goal:** one governed analytics platform that answers the same question the same way for
everyone. It should give risk and marketing decision-grade data within minutes, and each
person must see only what they are entitled to see.

## 2. Requirements

### Functional

| # | Requirement | Where it lives |
|---|---|---|
| F1 | Replicate 20 operational tables from Postgres without touching the core banking app | `02_ingestion_python` |
| F2 | Report every amount in local currency **and** USD, with the rate that applied that day | `int_fx_rates_daily_filled`, `fct_transactions` |
| F3 | Customer history as it was on any date (segment, risk band, KYC) | `snap_customers` (SCD2), point-in-time joins |
| F4 | One conformed set of dimensions shared by every fact | [`BUS_MATRIX.md`](../07_data_modelling/BUS_MATRIX.md) |
| F5 | Card decisioning, fraud flags, next best offer, sale-period uplift | `marts/cards`, `09_decisioning_python` |
| F6 | Answer questions in plain English, scoped to the person asking | `10_semantic_app` |
| F7 | Find a record from part of an identifier, across transactions, accounts, customers and card authorizations, still scoped to the person asking | `omni_search`, ADR 0009 |

### Non-functional (these drive the architecture, so they are numbers, not adjectives)

| NFR | Target | How it is measured | Consequence if missed |
|---|---|---|---|
| Freshness of hot facts | ≤ 15 min, p95 | `dbt source freshness`, run every 15 min by `meridian_source_freshness` | Fraud and branch ops act on stale data |
| Freshness of dims and aggregates | Available by 06:00 local | Daily DAG SLA | Morning branch huddle uses yesterday-minus-one |
| Correctness | 0 failing `error` tests in prod | `dbt build` gate | Run stops; consumers keep yesterday's good data |
| Reconciliation | 0 mismatched date/currency or date/branch groups after the 2-minute fair cutoff; posted amount difference < $0.01 | `reconcile_with_pandas.py` | Incident; nobody publishes numbers |
| Access | Deny by default; every read auditable | Row access policies, `ACCESS_HISTORY` | Regulatory breach |
| Recovery point (RPO) | ≤ 1 day for marts, ≤ 1 batch for raw | Raw is append-only + Time Travel 7 days | Rebuild marts from raw |
| Recovery time (RTO) | ≤ 4 h for marts | Full `dbt build` measured on WH_TRANSFORM_M | |
| Cost | ≤ the monthly credit quota | Resource monitor suspends at 90% | Warehouses stop, not the budget |

## 3. Architecture

```
Postgres (OLTP)  --watermark extract, Parquet-->  Snowflake RAW (VARIANT, append-only)
                                                       |
                                                 dbt: staging -> intermediate -> marts (Kimball)
                                                       |                         \
                     Training job (Python, role MERIDIAN_ML) <-- gold features    \
                              | scores + run metadata                              \
                              v                                                     v
                     MERIDIAN_RAW.ML  ----> dbt staging ----> scored marts --> Semantic view --> App
                                                                                (row access + masking)
                     marts --> omni_search (one row per identifier) -----------> App "find"
Orchestration: Airflow (5-min hot path, daily reference batch, card decisioning,
freshness watchdog, operator-triggered bounded replay)
Platform objects: Terraform. Data objects and grants: dbt. Entitlements: security (SQL).
```

Each arrow is a decision. Each decision has an ADR:

| ADR | Decision |
|---|---|
| [0001](adr/0001-watermark-cdc-before-log-based.md) | Watermark CDC first, log-based CDC as the upgrade path |
| [0002](adr/0002-append-only-variant-raw.md) | Raw is append-only VARIANT, not typed tables |
| [0003](adr/0003-kimball-for-the-presentation-layer.md) | Kimball star schemas over Data Vault or one big table |
| [0004](adr/0004-dbt-plus-airflow.md) | dbt + Airflow rather than Dynamic Tables or Tasks alone |
| [0005](adr/0005-model-scores-land-in-the-warehouse.md) | Model scores land in the warehouse, never in the OLTP |
| [0006](adr/0006-row-access-by-user-entitlements-owned-by-security.md) | Row access keyed on the user, entitlements owned by security |
| [0007](adr/0007-open-table-formats-deferred.md) | Apache Iceberg deferred, with a trigger to revisit |
| [0008](adr/0008-one-owner-per-object-type.md) | Terraform for platform, dbt for data, SQL for entitlements |
| [0009](adr/0009-omni-search-is-a-serving-index.md) | Identifier search is a serving index, not a second search engine |
| [0010](adr/0010-contracts-at-public-boundaries.md) | Contracts protect stable public marts, not every private model |

## 4. Capacity and cost

Write the arithmetic down. Interviewers ask for this, and it catches bad designs before
they ship.

### Volumes

| Entity | Course seed | Production assumption | Growth |
|---|---|---|---|
| Customers | 200 k | 6 M | 8 % / yr |
| Accounts | ~300 k | 9 M | 8 % / yr |
| Transactions | 5 M over 3 yrs (~4.6 k/day) | 2 M/day (~380 per branch per day) | 15 % / yr |
| Card authorisations | seed-sized | 3 M/day | 20 % / yr |

**Storage (production).** A transaction row is about 250 bytes as JSON in raw. Snowflake's
columnar compression is typically 4–6×, so take 5×.
2 M × 250 B ÷ 5 ≈ **100 MB/day**, or about **36 GB/year** for transactions in raw. Doubling
it for marts gives ≈ 75 GB/year. At roughly $23/TB-month that costs a few dollars a month.
**Storage is not the cost problem. Compute is.**

**Compute: the micro-batch is the expensive part.** Snowflake bills per second, with a
60-second minimum each time a warehouse resumes. A 5-minute schedule means 288 runs/day.
If a run takes 90 s and the warehouse then idles for its 60 s auto-suspend:

```
288 runs × 150 s = 43,200 s = 12 XS-hours = 12 credits/day ≈ 360 credits/month
at an assumed $3/credit (check your edition, cloud and region) ≈ $1,080 / month
```

| Option | Freshness | Credits/month (est.) | Trade-off |
|---|---|---|---|
| 5-min micro-batch (built) | ≤ 10 min | ~360 | Simple, one code path |
| 15-min micro-batch | ≤ 20 min | ~120 | Meets the 15-min p95 NFR only if runs stay short. Check before switching. |
| Snowpipe Streaming + Dynamic Tables | seconds | serverless, usage-based | No warehouse idle tax, more moving parts (ADR 0001, 0004) |
| Hourly | ≤ 70 min | ~30 | Fails the fraud requirement |

**The architect's move.** The 5-minute cadence is justified for authorisations and
transactions, which feed fraud. It is not justified for `ref.countries`. Move reference
tables to the daily DAG and the hot path loses most of its tables. Write that in the
review.

**Daily batch.** A full `dbt build` on WH_TRANSFORM_M (4 credits/hour). If it takes about
20 min, that is 1.3 credits/day ≈ 40/month. Clustering `fct_transactions` by date (see
`06_performance_lab`) keeps the daily incremental merge from scanning history. The lab
measures partitions scanned before and after.

## 5. Data classification and access

| Class | Examples | Control |
|---|---|---|
| Restricted | Full PAN, CVV | **Never stored.** Only `last4` and a token exist. |
| Confidential: PII | Email, phone, date of birth, income | Tag `GOVERNANCE.PII` → masking policy. Staff persona sees it masked. |
| Confidential: customer | Balances, transactions, cards | Row access policy: customer sees own rows, branch roles see their branch, CEO sees all |
| Internal | Branch aggregates, employee roster | Row access by branch. Customers have **no grant at all**. |
| Training labels | `fraud_label` | Never a model feature. `assert_no_leakage` enforces it. |

Model: deny by default. A user who is not mapped in `GOVERNANCE.APP_USER` sees zero rows,
even through the app's owner role. See ADR 0006.

## 6. Failure modes

| Failure | Detection | Blast radius control |
|---|---|---|
| Extract crashes after COPY, before watermark update | Next run re-reads the same window | Raw is append-only; staging dedupes on PK + `_extracted_at` (idempotent) |
| Source deletes a row | `cdc.deleted_records` tombstones | Staging filters deleted keys |
| Late FX rate (weekend, holiday) | `rate_age_days`, `is_forward_filled` | Forward-fill, flagged; unit test proves it |
| Upstream column renamed or required raw key disappears | Three public contracts + raw drift sentinel | Build warns at raw and fails before contracted consumers break |
| A bad model is trained | Holdout AUC gate (0.70) | Run marked `REJECTED`; marts keep the last good scores |
| Someone searches with part of an id | `CONTAINS` on `omni_search` | Substring Search Optimization; row policy still applies; fragments shorter than 4 characters are rejected |
| Fraud labels leak into features | `assert_no_leakage` + pytest | Training refuses to start |
| Mart rebuilt with `CREATE OR REPLACE` drops its policy | dbt post-hook re-attaches every build | If governance is not installed, the hook warns and the table has no grants. Deny, not leak. |
| Runaway query | Resource monitor at 75 / 90 / 100 % | Warehouses suspend |

## 7. What was deliberately left out

Knowing what not to build is part of the job.

* **Data Vault.** One source system and a small team. The extra hub/link/satellite
  layer would be pure cost here (ADR 0003).
* **Real-time streaming for everything.** Only fraud needs seconds. The design names the
  upgrade path instead of paying for it on day one (ADR 0001).
* **A feature store product.** A single dbt model, `ml_customer_features`, is the feature
  store at this scale. Training and serving read the same table, so there is no skew.
* **Iceberg.** No second engine needs the data yet (ADR 0007).
* **A search engine beside the warehouse.** Identifier search is a narrow table plus Search Optimization. Elasticsearch earns its place when the thing being searched is documents, not ids (ADR 0009).

## 8. Open risks

1. Tag-based masking with a `NUMBER(18,2)` policy requires the tagged column's type to
   match. A column created as `NUMBER(38,2)` will error at query time. Mitigation: cast in
   the model, and add a test that queries each tagged column as the STAFF persona.
2. The micro-batch watermark depends on `updated_at` being maintained by triggers. A bulk
   fix applied with triggers disabled will be invisible. Mitigation: daily reconciliation,
   and ADR 0001's log-based upgrade.
3. Single Airflow deployment. Mitigation: DAGs are idempotent, so a re-run after an outage
   is safe.
4. Cross-region/account failover is not validated on the course trial. The measured
   single-account recovery procedure and production upgrade path are in
   [`DR_RUNBOOK.md`](DR_RUNBOOK.md).
