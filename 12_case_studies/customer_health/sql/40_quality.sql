-- BI reads this view. The snapshot table stores the partition; the view adds the trend.
-- dbt would materialize both objects. It would not answer the dashboard query.

CREATE VIEW mart_customer_success_health AS
SELECT
    f.*,
    mrr_usd - LAG(mrr_usd) OVER (
        PARTITION BY salesforce_account_id
        ORDER BY snapshot_date
    ) AS mrr_change_usd
FROM fct_account_health_daily AS f;

CREATE VIEW recon_mrr AS
SELECT
    p.snapshot_date,
    (
        SELECT COALESCE(SUM(mrr_usd), 0)
        FROM fct_account_health_daily AS f
        WHERE f.snapshot_date = p.snapshot_date
    ) AS mart_mrr_usd,
    (
        SELECT COALESCE(SUM(mrr_usd), 0)
        FROM int_subscription_mrr
        WHERE salesforce_account_id IS NOT NULL
    ) AS subscription_mrr_usd
FROM run_params AS p;

CREATE VIEW recon_accounts AS
SELECT
    p.snapshot_date,
    (
        SELECT COUNT(*)
        FROM fct_account_health_daily AS f
        WHERE f.snapshot_date = p.snapshot_date
    ) AS mart_accounts,
    (
        SELECT COUNT(*)
        FROM dim_account
    ) AS source_customer_accounts
FROM run_params AS p;

CREATE VIEW recon_exceptions AS
SELECT
    'stripe' AS source_system,
    stripe_customer_id AS source_account_id,
    SUM(mrr_usd) AS unrecognized_mrr_usd,
    'no_crosswalk' AS reason
FROM int_subscription_mrr
WHERE salesforce_account_id IS NULL
GROUP BY stripe_customer_id

UNION ALL

SELECT
    'product' AS source_system,
    product_account_id AS source_account_id,
    NULL AS unrecognized_mrr_usd,
    'no_crosswalk' AS reason
FROM int_user_activity
WHERE salesforce_account_id IS NULL
GROUP BY product_account_id;

CREATE VIEW dq_grain_violations AS
SELECT
    snapshot_date,
    salesforce_account_id,
    COUNT(*) AS row_count
FROM fct_account_health_daily
GROUP BY snapshot_date, salesforce_account_id
HAVING COUNT(*) > 1;

CREATE VIEW dq_accepted_range_violations AS
SELECT
    snapshot_date,
    salesforce_account_id,
    'score_or_band' AS violation
FROM fct_account_health_daily
WHERE (health_score IS NOT NULL AND (health_score < 0 OR health_score > 100))
    OR (activity_score IS NOT NULL AND (activity_score < 0 OR activity_score > 100))
    OR (adoption_score IS NOT NULL AND (adoption_score < 0 OR adoption_score > 100))
    OR (csat_score IS NOT NULL AND (csat_score < 0 OR csat_score > 100))
    OR (support_score IS NOT NULL AND (support_score < 0 OR support_score > 100))
    OR risk_band NOT IN ('High', 'Medium', 'Low', 'Unknown')
    OR publish_status NOT IN ('published', 'stale_hold')
    OR health_score_version <> 'v1'
    OR mrr_usd < 0
    OR priority_score < 0
    OR ABS(priority_score - (risk_weight * revenue_at_risk_usd * renewal_urgency)) > 0.001
    OR revenue_at_risk_usd <> mrr_usd;

CREATE VIEW dq_relationship_violations AS
SELECT
    'mart_account_missing_stripe_crosswalk' AS violation,
    salesforce_account_id AS object_id
FROM fct_account_health_daily
WHERE salesforce_account_id NOT IN (
    SELECT salesforce_account_id
    FROM raw_account_crosswalk
    WHERE source_system = 'stripe'
        AND record_label = 'SYNTHETIC'
)

UNION ALL

SELECT
    'mart_account_missing_salesforce' AS violation,
    salesforce_account_id AS object_id
FROM fct_account_health_daily
WHERE salesforce_account_id NOT IN (
    SELECT salesforce_account_id
    FROM raw_salesforce_accounts
    WHERE record_label = 'SYNTHETIC'
)

UNION ALL

SELECT
    'crosswalk_without_salesforce_account' AS violation,
    salesforce_account_id AS object_id
FROM raw_account_crosswalk
WHERE record_label = 'SYNTHETIC'
    AND salesforce_account_id NOT IN (
        SELECT salesforce_account_id
        FROM raw_salesforce_accounts
        WHERE record_label = 'SYNTHETIC'
    );

-- Positive class is High only. Medium is not an automated outreach prediction.
-- Release bar: precision >= 0.70 and recall >= 0.80. The synthetic history misses that bar.
CREATE VIEW backtest_high_risk AS
WITH scored AS (
    SELECT
        f.salesforce_account_id,
        f.risk_band,
        CAST(c.churned_within_30d AS INTEGER) AS churned_within_30d
    FROM fct_account_health_daily AS f
    INNER JOIN raw_churn_outcomes AS c
        ON c.salesforce_account_id = f.salesforce_account_id
        AND CAST(c.observation_snapshot_date AS DATE) = f.snapshot_date
    WHERE c.record_label = 'SYNTHETIC'
        AND f.snapshot_date = DATE '2026-09-01'
),
counts AS (
    SELECT
        SUM(CASE WHEN risk_band = 'High' AND churned_within_30d = 1 THEN 1 ELSE 0 END) AS true_positive,
        SUM(CASE WHEN risk_band = 'High' AND churned_within_30d = 0 THEN 1 ELSE 0 END) AS false_positive,
        SUM(CASE WHEN risk_band <> 'High' AND churned_within_30d = 1 THEN 1 ELSE 0 END) AS false_negative
    FROM scored
)
SELECT
    true_positive,
    false_positive,
    false_negative,
    CASE
        WHEN true_positive + false_positive = 0 THEN NULL
        ELSE true_positive * 1.0 / (true_positive + false_positive)
    END AS precision,
    CASE
        WHEN true_positive + false_negative = 0 THEN NULL
        ELSE true_positive * 1.0 / (true_positive + false_negative)
    END AS recall
FROM counts;

CREATE VIEW score_release_gate AS
SELECT
    precision,
    recall,
    CASE
        WHEN precision >= 0.70 AND recall >= 0.80 THEN 'approved_for_ranked_outreach'
        ELSE 'withhold_automated_outreach'
    END AS release_decision
FROM backtest_high_risk;

CREATE VIEW dq_activity_drift AS
SELECT
    salesforce_account_id,
    MAX(CASE WHEN snapshot_date = DATE '2026-09-01' THEN activity_score END) AS activity_sep,
    MAX(CASE WHEN snapshot_date = DATE '2026-10-01' THEN activity_score END) AS activity_oct
FROM fct_account_health_daily
GROUP BY salesforce_account_id;
