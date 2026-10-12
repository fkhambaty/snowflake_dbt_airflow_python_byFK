-- Health score v1.
-- Components are 0-100 before weighting.
-- Weights: activity 0.40, adoption 0.30, csat 0.20, support 0.10.
-- If at least 3 components are present, renormalize those weights to 1.
-- Unknown when account_age_days < 30 or fewer than 3 components are present.
-- Support score 100 means no burden. A burden of 5 points per active user scores 0.
-- CSAT uses a 1-5 survey scaled to 0-100 and is unscored when fewer than 3 responses exist.
-- priority_score = risk_weight * revenue_at_risk_usd * renewal_urgency.
-- Risk weights: High 3, Medium 2, Low 1, Unknown 0.
-- Renewal urgency: overdue 4, <=30 days 3, <=90 days 2, <=180 days 1, otherwise 0.5.

CREATE VIEW int_account_health_snapshot AS
WITH metrics AS (
    SELECT
        a.snapshot_date,
        a.as_of_timestamp,
        a.business_timezone,
        a.health_score_version,
        'fx_policy_v1_latest_rate_on_or_before_period_start' AS fx_policy,
        f.publish_status,
        a.salesforce_account_id,
        a.account_name,
        a.csm_name,
        a.csm_email_masked,
        a.segment,
        a.region,
        a.product,
        a.onboarded_date,
        a.account_age_days,
        a.renewal_date,
        a.renewal_quarter,
        a.days_to_renewal,
        a.renewal_urgency,
        CAST(COALESCE(m.mrr_usd, 0) AS DECIMAL(18, 2)) AS mrr_usd,
        CAST(COALESCE(n.excluded_tax_usd, 0) AS DECIMAL(18, 2)) AS excluded_tax_usd,
        CAST(COALESCE(n.excluded_one_off_usd, 0) AS DECIMAL(18, 2)) AS excluded_one_off_usd,
        CAST(COALESCE(m.excluded_refund_mrr_usd, 0) AS DECIMAL(18, 2)) AS excluded_refund_mrr_usd,
        CAST(COALESCE(m.excluded_failed_mrr_usd, 0) AS DECIMAL(18, 2)) AS excluded_failed_mrr_usd,
        m.non_usd_fx_rate,
        COALESCE(u.active_users, 0) AS active_users,
        COALESCE(u.eligible_users, 0) AS eligible_users,
        CASE
            WHEN COALESCE(u.eligible_users, 0) = 0 THEN NULL
            ELSE CAST(ROUND(LEAST(100, 100.0 * u.active_users / u.eligible_users), 4) AS DECIMAL(18, 4))
        END AS activity_score,
        COALESCE(ad.features_used, 0) AS features_used,
        COALESCE(ad.features_entitled, 0) AS features_entitled,
        CASE
            WHEN COALESCE(ad.features_entitled, 0) = 0 THEN NULL
            ELSE CAST(ROUND(LEAST(100, 100.0 * ad.features_used / ad.features_entitled), 4) AS DECIMAL(18, 4))
        END AS adoption_score,
        COALESCE(s.ticket_count_90d, 0) AS ticket_count_90d,
        CAST(ROUND(COALESCE(s.support_burden_points, 0), 4) AS DECIMAL(18, 4)) AS support_burden_points,
        CASE
            WHEN COALESCE(u.active_users, 0) = 0 THEN NULL
            ELSE CAST(ROUND(COALESCE(s.support_burden_points, 0) / u.active_users, 4) AS DECIMAL(18, 4))
        END AS support_burden_per_active_user,
        CASE
            WHEN COALESCE(u.active_users, 0) = 0 THEN NULL
            ELSE CAST(ROUND(
                GREATEST(
                    0,
                    LEAST(
                        100,
                        100 * (1 - (COALESCE(s.support_burden_points, 0) / u.active_users) / 5.0)
                    )
                ),
                4
            ) AS DECIMAL(18, 4))
        END AS support_score,
        COALESCE(c.csat_responses_90d, 0) AS csat_responses_90d,
        CASE
            WHEN COALESCE(c.csat_responses_90d, 0) = 0 THEN NULL
            ELSE CAST(ROUND(c.csat_average_90d, 4) AS DECIMAL(18, 4))
        END AS csat_average_90d,
        CASE
            WHEN COALESCE(c.csat_responses_90d, 0) < 3 THEN NULL
            ELSE CAST(ROUND((c.csat_average_90d - 1) / 4.0 * 100, 4) AS DECIMAL(18, 4))
        END AS csat_score
    FROM dim_account AS a
    CROSS JOIN int_source_freshness AS f
    LEFT JOIN int_account_mrr AS m
        ON m.salesforce_account_id = a.salesforce_account_id
    LEFT JOIN int_account_nonrecurring AS n
        ON n.salesforce_account_id = a.salesforce_account_id
    LEFT JOIN int_account_usage_30d AS u
        ON u.salesforce_account_id = a.salesforce_account_id
    LEFT JOIN int_account_adoption AS ad
        ON ad.salesforce_account_id = a.salesforce_account_id
    LEFT JOIN int_account_support_90d AS s
        ON s.salesforce_account_id = a.salesforce_account_id
    LEFT JOIN int_account_csat_90d AS c
        ON c.salesforce_account_id = a.salesforce_account_id
),
weighted AS (
    SELECT
        metrics.*,
        (
            CASE WHEN activity_score IS NOT NULL THEN 1 ELSE 0 END
            + CASE WHEN adoption_score IS NOT NULL THEN 1 ELSE 0 END
            + CASE WHEN csat_score IS NOT NULL THEN 1 ELSE 0 END
            + CASE WHEN support_score IS NOT NULL THEN 1 ELSE 0 END
        ) AS components_present,
        (
            COALESCE(activity_score, 0) * CAST(0.40 AS DECIMAL(10, 4))
            + COALESCE(adoption_score, 0) * CAST(0.30 AS DECIMAL(10, 4))
            + COALESCE(csat_score, 0) * CAST(0.20 AS DECIMAL(10, 4))
            + COALESCE(support_score, 0) * CAST(0.10 AS DECIMAL(10, 4))
        ) AS weighted_numerator,
        (
            CASE WHEN activity_score IS NOT NULL THEN CAST(0.40 AS DECIMAL(10, 4)) ELSE 0 END
            + CASE WHEN adoption_score IS NOT NULL THEN CAST(0.30 AS DECIMAL(10, 4)) ELSE 0 END
            + CASE WHEN csat_score IS NOT NULL THEN CAST(0.20 AS DECIMAL(10, 4)) ELSE 0 END
            + CASE WHEN support_score IS NOT NULL THEN CAST(0.10 AS DECIMAL(10, 4)) ELSE 0 END
        ) AS present_weight
    FROM metrics
),
scored AS (
    SELECT
        weighted.*,
        CASE
            WHEN account_age_days < 30 THEN 'newly_onboarded'
            WHEN components_present < 3 THEN 'insufficient_components'
            ELSE NULL
        END AS unknown_reason,
        CASE
            WHEN account_age_days < 30 OR components_present < 3 THEN NULL
            ELSE CAST(ROUND(
                LEAST(
                    100,
                    GREATEST(0, weighted_numerator / NULLIF(present_weight, 0))
                ),
                4
            ) AS DECIMAL(18, 4))
        END AS health_score
    FROM weighted
)
SELECT
    snapshot_date,
    as_of_timestamp,
    business_timezone,
    health_score_version,
    fx_policy,
    publish_status,
    salesforce_account_id,
    account_name,
    csm_name,
    csm_email_masked,
    segment,
    region,
    product,
    onboarded_date,
    account_age_days,
    renewal_date,
    renewal_quarter,
    days_to_renewal,
    renewal_urgency,
    mrr_usd,
    excluded_tax_usd,
    excluded_one_off_usd,
    excluded_refund_mrr_usd,
    excluded_failed_mrr_usd,
    non_usd_fx_rate,
    active_users,
    eligible_users,
    activity_score,
    features_used,
    features_entitled,
    adoption_score,
    ticket_count_90d,
    support_burden_points,
    support_burden_per_active_user,
    support_score,
    csat_responses_90d,
    csat_average_90d,
    csat_score,
    components_present,
    unknown_reason,
    health_score,
    CASE
        WHEN health_score IS NULL THEN 'Unknown'
        WHEN health_score < 50 THEN 'High'
        WHEN health_score < 75 THEN 'Medium'
        ELSE 'Low'
    END AS risk_band,
    CASE
        WHEN health_score IS NULL THEN 0
        WHEN health_score < 50 THEN 3
        WHEN health_score < 75 THEN 2
        ELSE 1
    END AS risk_weight,
    mrr_usd AS revenue_at_risk_usd,
    CAST(ROUND(
        CASE
            WHEN health_score IS NULL THEN 0
            WHEN health_score < 50 THEN 3
            WHEN health_score < 75 THEN 2
            ELSE 1
        END * mrr_usd * renewal_urgency,
        4
    ) AS DECIMAL(18, 4)) AS priority_score
FROM scored;

CREATE TABLE fct_account_health_daily AS
SELECT *
FROM int_account_health_snapshot
WHERE FALSE;
