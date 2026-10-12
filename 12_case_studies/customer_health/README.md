# AcmeCloud customer-health case

Synthetic interview case. Every seed row has `record_label = SYNTHETIC`. None of these accounts, payments, tickets, or people are real.

The published mart has **one row per Salesforce account per snapshot date**. That sentence is the grain. Display name is an attribute. It is never a join key.

Run it from `DataEngineeringAndAnalyticsByFK`:

```bash
python3 -m pytest tests/test_customer_health_case.py -q
python3 12_case_studies/customer_health/run_case.py
```

DuckDB executes the SQL in memory. The same grain, keys, and metric rules are what a Snowflake and dbt implementation would publish. Function names differ (`DATE_DIFF` versus `DATEDIFF`, `AT TIME ZONE` versus `CONVERT_TIMEZONE`). `QUALIFY` is valid in both DuckDB and Snowflake.

## What the mart decides

| Question | Rule in this case |
| --- | --- |
| Who is the account? | `salesforce_account_id`, through `account_crosswalk` |
| What is MRR? | Active recurring contract value, normalized to a month, in USD |
| What is excluded from MRR? | Tax, one-offs, refunds, and failed payments |
| FX | `fx_policy_v1_latest_rate_on_or_before_period_start`. USD is 1. Any other currency uses the latest rate on or before the covering invoice's `period_start` |
| Active user | Distinct eligible user with `session_start`, `page_view`, or `feature_used` in the local 30-day window |
| Window clock | `America/New_York`. Activity is `[snapshot_date - 29 days, snapshot_date]`. Support and CSAT are 90 inclusive local days |
| Not an active user | Bots, `is_internal` users, and `@acmecloud.example` addresses |
| Adoption | Entitled features used in that window, divided by features entitled. Unentitled features do not count. v1 does not weight features |
| Support | Sum of `severity weight * (1 + unresolved age in days / 30)`, divided by active users. Solved or closed tickets contribute age 0. Weights: low 1, medium 2, high 3, urgent 5. Age is capped at 90 |
| Support score | 100 means no burden. Five burden points per active user scores 0. Null when there are no active users |
| CSAT | 90-day mean of 1–5 responses, scaled with `(average - 1) / 4 * 100`. Fewer than 3 responses leaves the score null. The average can still be shown |
| Health score v1 | `0.40 activity + 0.30 adoption + 0.20 csat + 0.10 support`, after each input is on 0–100. If at least three components exist, the present weights are renormalized. Otherwise the score is null |
| Unknown | Account age under 30 days (`newly_onboarded`) or fewer than three components (`insufficient_components`) |
| Risk | High below 50, Medium from 50 up to but not including 75, Low at 75 and above, else Unknown |
| Priority | `risk_weight * current MRR USD * renewal urgency` |
| Risk weights | High 3, Medium 2, Low 1, Unknown 0 |
| Renewal urgency | Overdue 4, within 30 days 3, within 90 days 2, within 180 days 1, otherwise 0.5 |
| Late data | A row counts only when `loaded_at <= as_of`. Rebuilding the snapshot date with a later `as_of` is how it appears |
| Freshness | Salesforce and Stripe extract watermarks must both be within 36 hours of `as_of`, or `publish_status = stale_hold` |
| Dedupe | Latest `updated_at`, then highest `source_row_id`. Not `SELECT DISTINCT` |

Unknown accounts stay on the mart with MRR and a zero priority. They need a data check. They do not jump the outreach queue, and they are not labelled Low.

## Six-week delivery, and what to drop

| Period | Deliverable | Why it is first |
| --- | --- | --- |
| Week 1 | Grain, metric dictionary, source owners, and the crosswalk | Stops a rebuild after the definitions are disputed |
| Weeks 1–2 | Salesforce and Stripe ingestion, account reconciliation, MRR | This is the commercial MVP |
| Weeks 2–3 | Staging, the account dimension, and the revenue mart | Tests have a stable base |
| Weeks 3–4 | Product usage and Zendesk aggregates | Behaviour and service signals |
| Week 5 | Back-test the score with 2–3 CSMs | Usefulness before a wide launch |
| Week 6 | Security review, UAT, runbook, phased rollout | A controlled release |

If week 6 is at risk, ship renewal date, normalized MRR, MRR change, and active users. Do not pretend an unvalidated weighted score is safe to automate.

This case still calculates health score v1 so the interview can defend the math. The release gate does not approve it. On the labelled September history, High-risk precision is 1.0 and recall is 0.5, because Medium Co churned without being High. The gate requires precision at least 0.70 and recall at least 0.80. The decision is `withhold_automated_outreach`. Show the components. Do not auto-rank a CSM's day from v1.

## MVP versus the full score

The MVP columns are `salesforce_account_id`, CSM, segment, region, product, `renewal_date`, `renewal_quarter`, `mrr_usd`, `mrr_change_usd`, and `active_users`.

The score, the band, and `priority_score` are a versioned hypothesis. Changing a weight, the CSAT sample size, the support scale, or the Unknown rule is a new version, not a silent edit. v1 is stored on every row as `health_score_version`.

## Tables and views

| Object | Form here | Form in the warehouse | Why |
| --- | --- | --- | --- |
| `stg_*` | View | View | Thin cleanse. Cheap to rebuild. Carries the dedupe and the `as_of` filter |
| Usage, adoption, support, CSAT, MRR intermediates | View | Incremental tables once event volume matters | This seed is small. Production event tables should not full-refresh forever |
| `fct_account_health_daily` | Table | Incremental table, one partition per `snapshot_date` | History, trends, and back-tests need a stored snapshot |
| `mart_customer_success_health` | View over the table | View or a thin presentation table | Adds MRR change with `LAG`. BI reads this object |

Staging can stay a view. The daily account snapshot should be a table. Choose from volume, freshness, and the latency the dashboard actually needs.

## dbt builds the object. BI reads Snowflake

dbt compiles the models and materializes the Snowflake table or view. The BI tool connects to a dedicated Snowflake warehouse and queries that presentation object. dbt does not serve the dashboard request.

In this laptop case, `run_case.py` is the stand-in for that build. `mart_customer_success_health` is the object a dashboard would query.

Model layout the warehouse version would use:

- Staging: `stg_salesforce__accounts`, `stg_salesforce__renewals`, `stg_stripe__subscriptions`, `stg_stripe__invoices`, `stg_stripe__payments`, `stg_product__users`, `stg_product__events`, `stg_product__entitlements`, `stg_zendesk__tickets`, `stg_zendesk__csat`, `stg_account_crosswalk`
- Intermediate: `int_subscription_mrr`, `int_account_mrr`, `int_account_usage_30d`, `int_account_adoption`, `int_account_support_90d`, `int_account_csat_90d`
- Presentation: `dim_account`, `fct_account_health_daily`, `mart_customer_success_health`

Staging reads `source()`. Everything downstream reads `ref()`. Aggregates are at account grain before they are joined.

## Incremental and idempotent

Raw landings stay append-only. This case stores the already-landed files as seed CSVs with `loaded_at`.

A snapshot build does two writes:

1. Replace the single `pipeline_run` cutoff (`snapshot_date`, `as_of_timestamp`).
2. Delete `fct_account_health_daily` for that `snapshot_date` only, then insert the current result.

Running the same date and the same `as_of` again yields the same partition. Running a later `as_of` replaces that date and leaves other dates in place. A late product event is included only after its `loaded_at` is on or before `as_of`. Moving `as_of` backward removes it again.

Production orchestration retries the failed task, records the load, and reruns the affected snapshot dates. It does not reload the whole history after one late file. Product-event cost is contained by incremental event models plus this daily account snapshot, not by a daily full refresh of every event.

`SELECT DISTINCT` is not the dedupe. It would hide a bad join after revenue had already been multiplied. Each source is reduced with a deterministic `ROW_NUMBER` before the account join.

## Late data and freshness

Two different clocks:

- `occurred_at` or `created_at` decides which window the fact belongs to.
- `loaded_at` decides whether this build is allowed to see it.
- `as_of_timestamp` is stored on the mart row so a CSM can see which cutoff they are looking at.

Commercial freshness uses the extract watermark in `source_extracts`, not the maximum historical row timestamp. Salesforce and Stripe must both have a watermark within 36 hours of `as_of`. If either is older, the row is still calculated and marked `stale_hold`. The dashboard labels the refresh. It does not silently publish a stale score as current, and it does not delete the account.

A late product event can arrive while the commercial extracts are still fresh. The fix is to replay the snapshot dates whose windows contain that event, with a new `as_of`. Source freshness should also alert the owning team.

## Security, PII, and CSM row access

Internal staff are not trusted for every row. Revenue and contact data still need a boundary.

- Separate roles for loading raw data, building the mart, and reading the presentation schema. Least privilege by layer.
- The mart carries `csm_name` so a Snowflake row-access policy can restrict a CSM to their accounts. The policy lives with Security, not inside the metric SQL. A filter on `csm_name` is the local proof that the column is there; it is not the production policy.
- `csm_email` stays in staging. The mart publishes `csm_email_masked` (`***@domain`). Product-user emails are not selected into the mart.
- Do not land raw Stripe card payloads in the presentation schema. This model uses subscription, invoice, and payment facts only.
- Service-account authentication, secret rotation, and audit logs on the warehouse.
- A small BI warehouse with auto-suspend and a resource monitor. Do not let dashboard queries run on the transformation warehouse.

## Owners and runbook

| Concern | Owner |
| --- | --- |
| Crosswalk and account identity | Analytics engineering. Salesforce operations confirms source ids |
| MRR definition and exclusions | Finance systems partner and analytics engineering |
| Health-score formula and release bar | Customer Success operations. Analytics engineering implements the version |
| Dashboard | BI |
| Pipeline, freshness, replay | Data platform on-call |
| Row-access policy | Security |

When a refresh looks wrong:

1. Read `publish_status`, `as_of_timestamp`, and the Salesforce and Stripe watermarks.
2. If the status is `stale_hold`, do not brief CSMs from that refresh. Page the source owner.
3. After the source recovers, rerun only the snapshot dates whose windows overlap the late or missing data, with the new `as_of`.
4. Check `dq_grain_violations`, `dq_accepted_range_violations`, `dq_relationship_violations`, `recon_mrr`, `recon_accounts`, and `recon_exceptions`.
5. Unmatched Stripe customers and product accounts must show up as exceptions. They must not disappear, and they must not become a fake account.
6. Run the same snapshot again. The partition must be unchanged. Then compare High-risk accounts with actual churn before anyone treats a new score version as approved.

Incident expectation: a missed commercial SLA is a freshness incident the same day. A definition change is a versioned release, not a hot fix inside the dashboard.

## Back-testing, precision, recall, and drift

Positive class for automated outreach is High only. Medium is not a positive prediction.

On the 2026-09-01 snapshot, compared with churn inside 30 days:

- Brightline Health was High and churned. That is a true positive.
- Medium Co was Medium and churned. That is a false negative.
- Precision is 1. Recall is 0.5.

That is enough to withhold automated ranking. A real back-test would do this by segment, region, and tenure, on more than four accounts, and would be refreshed when the formula version changes. The release bar in `score_release_gate` is explicit so the threshold is not a vibe.

Drift is why the snapshot exists. Northwind Labs keeps the same MRR from 1 September to 1 October while the activity score moves from 90 to 80, because one user sits on the New York side of the 30-day boundary. A current-state table cannot explain that. Watch component movement by segment. A flat MRR with a falling activity score is a review, not proof that the account is healthy.

## Files

- `seeds/` — labelled Salesforce, Stripe, FX, product, Zendesk, crosswalk, extract watermark, and churn files
- `sql/00_control.sql` — the run cutoff and local window bounds
- `sql/10_staging.sql` — deterministic dedupe and the `as_of` filter
- `sql/20_intermediate.sql` — MRR, usage, adoption, support, CSAT, freshness, account dimension
- `sql/30_snapshot.sql` — score, band, priority, and the snapshot table
- `sql/40_quality.sql` — mart, reconciliation, grain, ranges, relationships, back-test, drift
- `run_case.py` — loads the seeds, builds a snapshot partition, and can be imported by the test

`tests/test_customer_health_case.py` is the contract. It checks the grain, the crosswalk, dedupe, MRR exclusions, FX, the New York window, bots and internal users, adoption, support age, the CSAT sample rule, Unknown, priority, late `as_of` handling, stale labelling, idempotence, reconciliation, and the back-test gate.
