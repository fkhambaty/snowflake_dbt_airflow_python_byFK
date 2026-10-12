-- Intermediate aggregates are already at account grain before any mart join.
-- fx_policy_v1_latest_rate_on_or_before_period_start:
--   USD converts at 1.
--   Any other currency uses the latest rate whose rate_date is on or before the
--   covering invoice period_start. Later decoy rates must not apply.

CREATE VIEW int_source_freshness AS
WITH critical AS (
    SELECT
        source_system,
        MAX(CAST(loaded_at AS TIMESTAMP)) AS watermark
    FROM raw_source_extracts
    WHERE record_label = 'SYNTHETIC'
        AND source_system IN ('salesforce', 'stripe')
        AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
    GROUP BY source_system
),
gate AS (
    SELECT
        (SELECT COUNT(*) FROM critical) AS source_count,
        (SELECT MIN(watermark) FROM critical) AS oldest_watermark,
        (SELECT as_of_timestamp FROM pipeline_run) AS as_of_timestamp
)
SELECT
    CASE
        WHEN source_count < 2 THEN 'stale_hold'
        WHEN oldest_watermark < as_of_timestamp - INTERVAL 36 HOUR THEN 'stale_hold'
        ELSE 'published'
    END AS publish_status
FROM gate;

CREATE VIEW dim_account AS
SELECT
    p.snapshot_date,
    p.as_of_timestamp,
    p.business_timezone,
    p.health_score_version,
    a.salesforce_account_id,
    a.account_name,
    a.csm_name,
    CASE
        WHEN a.csm_email IS NULL OR STRPOS(a.csm_email, '@') = 0 THEN NULL
        ELSE '***@' || SPLIT_PART(a.csm_email, '@', 2)
    END AS csm_email_masked,
    a.segment,
    a.region,
    a.product,
    a.onboarded_date,
    DATE_DIFF('day', a.onboarded_date, p.snapshot_date) AS account_age_days,
    r.renewal_date,
    CASE
        WHEN r.renewal_date IS NULL THEN NULL
        ELSE CAST(YEAR(r.renewal_date) AS VARCHAR) || 'Q' || CAST(QUARTER(r.renewal_date) AS VARCHAR)
    END AS renewal_quarter,
    CASE
        WHEN r.renewal_date IS NULL THEN NULL
        ELSE DATE_DIFF('day', p.snapshot_date, r.renewal_date)
    END AS days_to_renewal,
    CAST(
        CASE
            WHEN r.renewal_date IS NULL THEN 0.5
            WHEN DATE_DIFF('day', p.snapshot_date, r.renewal_date) < 0 THEN 4
            WHEN DATE_DIFF('day', p.snapshot_date, r.renewal_date) <= 30 THEN 3
            WHEN DATE_DIFF('day', p.snapshot_date, r.renewal_date) <= 90 THEN 2
            WHEN DATE_DIFF('day', p.snapshot_date, r.renewal_date) <= 180 THEN 1
            ELSE 0.5
        END AS DECIMAL(10, 1)
    ) AS renewal_urgency
FROM stg_salesforce__accounts AS a
CROSS JOIN run_params AS p
LEFT JOIN stg_salesforce__renewals AS r
    ON r.salesforce_account_id = a.salesforce_account_id
WHERE a.status = 'customer'
    AND a.created_date <= p.snapshot_date;

CREATE VIEW int_invoice_payments AS
SELECT
    invoice_id,
    SUM(CASE WHEN payment_kind = 'charge' AND status = 'succeeded' THEN amount ELSE 0 END) AS charge_succeeded,
    SUM(CASE WHEN payment_kind = 'refund' AND status = 'succeeded' THEN amount ELSE 0 END) AS refund_succeeded,
    SUM(CASE WHEN payment_kind = 'charge' AND status = 'failed' THEN amount ELSE 0 END) AS charge_failed
FROM stg_stripe__payments
GROUP BY invoice_id;

CREATE VIEW int_subscription_mrr AS
WITH covering AS (
    SELECT
        s.subscription_id,
        s.stripe_customer_id,
        s.currency_code,
        s.billing_interval,
        s.unit_amount,
        i.invoice_id,
        i.amount AS invoice_amount,
        i.period_start
    FROM stg_stripe__subscriptions AS s
    INNER JOIN stg_stripe__invoices AS i
        ON i.subscription_id = s.subscription_id
        AND i.line_type = 'recurring'
        AND i.currency_code = s.currency_code
    CROSS JOIN run_params AS p
    WHERE s.status IN ('active', 'past_due')
        AND s.start_date <= p.snapshot_date
        AND (s.end_date IS NULL OR s.end_date > p.snapshot_date)
        AND i.period_start <= p.snapshot_date
        AND p.snapshot_date < i.period_end
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY s.subscription_id
        ORDER BY i.period_start DESC, i.invoice_id DESC
    ) = 1
),
rated AS (
    SELECT
        c.subscription_id,
        c.stripe_customer_id,
        c.currency_code,
        c.billing_interval,
        c.unit_amount,
        c.invoice_id,
        c.invoice_amount,
        c.period_start,
        x.salesforce_account_id,
        CASE
            WHEN c.currency_code = 'USD' THEN CAST(1 AS DECIMAL(18, 6))
            ELSE (
                SELECT f.usd_per_unit
                FROM stg_fx_rates AS f
                WHERE f.currency_code = c.currency_code
                    AND f.rate_date <= c.period_start
                ORDER BY f.rate_date DESC, f.source_row_id DESC
                LIMIT 1
            )
        END AS fx_rate,
        COALESCE(pay.charge_succeeded, 0) AS charge_succeeded,
        COALESCE(pay.refund_succeeded, 0) AS refund_succeeded,
        COALESCE(pay.charge_failed, 0) AS charge_failed
    FROM covering AS c
    LEFT JOIN int_invoice_payments AS pay
        ON pay.invoice_id = c.invoice_id
    LEFT JOIN stg_account_crosswalk AS x
        ON x.source_system = 'stripe'
        AND x.source_account_id = c.stripe_customer_id
),
valued AS (
    SELECT
        rated.*,
        CAST(
            CASE rated.billing_interval
                WHEN 'month' THEN rated.unit_amount
                WHEN 'year' THEN rated.unit_amount / 12
                WHEN 'quarter' THEN rated.unit_amount / 3
                ELSE NULL
            END AS DECIMAL(18, 6)
        ) AS monthly_native,
        CASE
            WHEN rated.invoice_amount = 0 THEN CAST(0 AS DECIMAL(18, 6))
            ELSE CAST(
                (rated.charge_succeeded - rated.refund_succeeded) / rated.invoice_amount
                AS DECIMAL(18, 6)
            )
        END AS net_ratio_raw
    FROM rated
)
SELECT
    salesforce_account_id,
    stripe_customer_id,
    subscription_id,
    currency_code,
    fx_rate,
    'fx_policy_v1_latest_rate_on_or_before_period_start' AS fx_policy,
    CASE
        WHEN fx_rate IS NULL OR monthly_native IS NULL THEN NULL
        ELSE CAST(ROUND(monthly_native * fx_rate, 2) AS DECIMAL(18, 2))
    END AS monthly_contract_usd,
    CASE
        WHEN fx_rate IS NULL THEN 'missing_fx'
        WHEN monthly_native IS NULL THEN 'unsupported_interval'
        WHEN (charge_succeeded - refund_succeeded) <= 0 AND charge_failed > 0 THEN 'failed_payment'
        WHEN (charge_succeeded - refund_succeeded) <= 0 AND refund_succeeded > 0 THEN 'refunded'
        WHEN (charge_succeeded - refund_succeeded) <= 0 THEN 'unpaid'
        ELSE 'included'
    END AS exclusion_reason,
    CASE
        WHEN fx_rate IS NULL OR monthly_native IS NULL THEN CAST(0 AS DECIMAL(18, 2))
        ELSE CAST(
            ROUND(
                monthly_native * fx_rate * LEAST(1, GREATEST(0, net_ratio_raw)),
                2
            ) AS DECIMAL(18, 2)
        )
    END AS mrr_usd,
    CASE
        WHEN fx_rate IS NULL OR monthly_native IS NULL OR invoice_amount = 0 THEN CAST(0 AS DECIMAL(18, 2))
        ELSE CAST(
            ROUND(
                monthly_native * fx_rate * LEAST(1, refund_succeeded / invoice_amount),
                2
            ) AS DECIMAL(18, 2)
        )
    END AS excluded_refund_mrr_usd,
    CASE
        WHEN fx_rate IS NULL OR monthly_native IS NULL THEN CAST(0 AS DECIMAL(18, 2))
        WHEN (charge_succeeded - refund_succeeded) <= 0 AND charge_failed > 0
            THEN CAST(ROUND(monthly_native * fx_rate, 2) AS DECIMAL(18, 2))
        ELSE CAST(0 AS DECIMAL(18, 2))
    END AS excluded_failed_mrr_usd
FROM valued;

CREATE VIEW int_account_mrr AS
SELECT
    salesforce_account_id,
    SUM(mrr_usd) AS mrr_usd,
    SUM(excluded_refund_mrr_usd) AS excluded_refund_mrr_usd,
    SUM(excluded_failed_mrr_usd) AS excluded_failed_mrr_usd,
    MAX(CASE WHEN currency_code <> 'USD' AND exclusion_reason = 'included' THEN fx_rate END) AS non_usd_fx_rate
FROM int_subscription_mrr
WHERE salesforce_account_id IS NOT NULL
GROUP BY salesforce_account_id;

CREATE VIEW int_account_nonrecurring AS
WITH priced AS (
    SELECT
        x.salesforce_account_id,
        i.line_type,
        i.amount * CASE
            WHEN i.currency_code = 'USD' THEN CAST(1 AS DECIMAL(18, 6))
            ELSE (
                SELECT f.usd_per_unit
                FROM stg_fx_rates AS f
                WHERE f.currency_code = i.currency_code
                    AND f.rate_date <= i.period_start
                ORDER BY f.rate_date DESC, f.source_row_id DESC
                LIMIT 1
            )
        END AS amount_usd
    FROM stg_stripe__invoices AS i
    CROSS JOIN run_params AS p
    LEFT JOIN stg_account_crosswalk AS x
        ON x.source_system = 'stripe'
        AND x.source_account_id = i.stripe_customer_id
    WHERE i.line_type IN ('tax', 'one_off')
        AND i.period_start <= p.snapshot_date
        AND p.snapshot_date < i.period_end
        AND x.salesforce_account_id IS NOT NULL
)
SELECT
    salesforce_account_id,
    CAST(ROUND(SUM(CASE WHEN line_type = 'tax' THEN amount_usd ELSE 0 END), 2) AS DECIMAL(18, 2)) AS excluded_tax_usd,
    CAST(ROUND(SUM(CASE WHEN line_type = 'one_off' THEN amount_usd ELSE 0 END), 2) AS DECIMAL(18, 2)) AS excluded_one_off_usd
FROM priced
GROUP BY salesforce_account_id;

CREATE VIEW int_product_users AS
SELECT
    u.user_id,
    u.product_account_id,
    u.email,
    u.is_bot,
    u.is_internal,
    x.salesforce_account_id,
    CASE
        WHEN u.is_bot THEN 'bot'
        WHEN u.is_internal THEN 'internal_user'
        WHEN LOWER(SPLIT_PART(u.email, '@', 2)) = 'acmecloud.example' THEN 'internal_domain'
        ELSE NULL
    END AS exclusion_reason
FROM stg_product__users AS u
CROSS JOIN run_params AS p
LEFT JOIN stg_account_crosswalk AS x
    ON x.source_system = 'product'
    AND x.source_account_id = u.product_account_id
WHERE CAST(u.created_at AS DATE) <= p.snapshot_date;

CREATE VIEW int_user_activity AS
WITH qualifying AS (
    SELECT
        e.user_id,
        COUNT(*) AS qualifying_events
    FROM stg_product__events AS e
    CROSS JOIN run_params AS p
    WHERE e.event_name IN ('session_start', 'page_view', 'feature_used')
        AND e.occurred_at >= (p.activity_start_local AT TIME ZONE p.business_timezone)
        AND e.occurred_at < (p.window_end_local AT TIME ZONE p.business_timezone)
    GROUP BY e.user_id
)
SELECT
    u.user_id,
    u.product_account_id,
    u.salesforce_account_id,
    u.exclusion_reason,
    u.exclusion_reason IS NULL AS is_eligible,
    COALESCE(q.qualifying_events, 0) > 0 AS has_qualifying_event,
    u.exclusion_reason IS NULL AND COALESCE(q.qualifying_events, 0) > 0 AS is_active
FROM int_product_users AS u
LEFT JOIN qualifying AS q
    ON q.user_id = u.user_id;

CREATE VIEW int_account_usage_30d AS
SELECT
    salesforce_account_id,
    COUNT(*) FILTER (WHERE is_eligible) AS eligible_users,
    COUNT(*) FILTER (WHERE is_active) AS active_users
FROM int_user_activity
WHERE salesforce_account_id IS NOT NULL
GROUP BY salesforce_account_id;

CREATE VIEW int_account_adoption AS
WITH params AS (
    SELECT * FROM run_params
),
entitled AS (
    SELECT
        x.salesforce_account_id,
        e.feature_key
    FROM stg_product__entitlements AS e
    INNER JOIN stg_account_crosswalk AS x
        ON x.source_system = 'product'
        AND x.source_account_id = e.product_account_id
    CROSS JOIN params AS p
    WHERE e.effective_from <= p.snapshot_date
        AND (e.effective_to IS NULL OR e.effective_to > p.snapshot_date)
),
used AS (
    SELECT DISTINCT
        u.salesforce_account_id,
        e.feature_key
    FROM stg_product__events AS e
    INNER JOIN int_product_users AS u
        ON u.user_id = e.user_id
        AND u.exclusion_reason IS NULL
        AND u.salesforce_account_id IS NOT NULL
    CROSS JOIN params AS p
    WHERE e.event_name = 'feature_used'
        AND e.feature_key IS NOT NULL
        AND e.occurred_at >= (p.activity_start_local AT TIME ZONE p.business_timezone)
        AND e.occurred_at < (p.window_end_local AT TIME ZONE p.business_timezone)
)
SELECT
    entitled.salesforce_account_id,
    COUNT(*) AS features_entitled,
    COUNT(used.feature_key) AS features_used
FROM entitled
LEFT JOIN used
    ON used.salesforce_account_id = entitled.salesforce_account_id
    AND used.feature_key = entitled.feature_key
GROUP BY entitled.salesforce_account_id;

CREATE VIEW int_account_support_90d AS
WITH scored AS (
    SELECT
        x.salesforce_account_id,
        t.ticket_id,
        CASE t.severity
            WHEN 'low' THEN 1
            WHEN 'medium' THEN 2
            WHEN 'high' THEN 3
            WHEN 'urgent' THEN 5
            ELSE NULL
        END AS severity_weight,
        CASE
            WHEN t.status IN ('solved', 'closed') THEN 0
            ELSE LEAST(
                90,
                DATE_DIFF(
                    'day',
                    CAST(TIMEZONE(p.business_timezone, t.created_at) AS DATE),
                    p.snapshot_date
                )
            )
        END AS unresolved_age_days
    FROM stg_zendesk__tickets AS t
    INNER JOIN stg_account_crosswalk AS x
        ON x.source_system = 'zendesk'
        AND x.source_account_id = t.zendesk_org_id
    CROSS JOIN run_params AS p
    WHERE t.created_at >= (p.lookback_90_start_local AT TIME ZONE p.business_timezone)
        AND t.created_at < (p.window_end_local AT TIME ZONE p.business_timezone)
)
SELECT
    salesforce_account_id,
    COUNT(*) AS ticket_count_90d,
    SUM(severity_weight * (1 + unresolved_age_days / 30.0)) AS support_burden_points
FROM scored
WHERE severity_weight IS NOT NULL
GROUP BY salesforce_account_id;

CREATE VIEW int_account_csat_90d AS
SELECT
    x.salesforce_account_id,
    COUNT(*) AS csat_responses_90d,
    AVG(c.score) AS csat_average_90d
FROM stg_zendesk__csat AS c
INNER JOIN stg_account_crosswalk AS x
    ON x.source_system = 'zendesk'
    AND x.source_account_id = c.zendesk_org_id
CROSS JOIN run_params AS p
WHERE c.responded_at >= (p.lookback_90_start_local AT TIME ZONE p.business_timezone)
    AND c.responded_at < (p.window_end_local AT TIME ZONE p.business_timezone)
GROUP BY x.salesforce_account_id;
