-- Staging: one deterministic survivor per business key.
-- Survivor rule: latest updated_at, then highest source_row_id. Rows loaded after as_of are invisible.
-- This is the late-data rule. A replay with a later as_of is what makes the late row appear.

CREATE VIEW stg_salesforce__accounts AS
SELECT
    salesforce_account_id,
    account_name,
    csm_name,
    csm_email,
    segment,
    region,
    product,
    CAST(onboarded_date AS DATE) AS onboarded_date,
    CAST(created_date AS DATE) AS created_date,
    status,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_salesforce_accounts
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY salesforce_account_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_salesforce__renewals AS
SELECT
    renewal_id,
    salesforce_account_id,
    CAST(renewal_date AS DATE) AS renewal_date,
    stage,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_salesforce_renewals
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY salesforce_account_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_stripe__subscriptions AS
SELECT
    subscription_id,
    stripe_customer_id,
    currency_code,
    billing_interval,
    CAST(unit_amount AS DECIMAL(18, 2)) AS unit_amount,
    status,
    CAST(start_date AS DATE) AS start_date,
    CAST(end_date AS DATE) AS end_date,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_stripe_subscriptions
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY subscription_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_stripe__invoices AS
SELECT
    invoice_id,
    CAST(line_number AS INTEGER) AS line_number,
    stripe_customer_id,
    subscription_id,
    currency_code,
    line_type,
    CAST(period_start AS DATE) AS period_start,
    CAST(period_end AS DATE) AS period_end,
    CAST(amount AS DECIMAL(18, 2)) AS amount,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_stripe_invoices
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY invoice_id, CAST(line_number AS INTEGER)
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_stripe__payments AS
SELECT
    payment_id,
    invoice_id,
    payment_kind,
    status,
    CAST(amount AS DECIMAL(18, 2)) AS amount,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_stripe_payments
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payment_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_fx_rates AS
SELECT
    currency_code,
    CAST(rate_date AS DATE) AS rate_date,
    CAST(usd_per_unit AS DECIMAL(18, 6)) AS usd_per_unit,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_fx_rates
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY currency_code, CAST(rate_date AS DATE)
    ORDER BY CAST(loaded_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_product__users AS
SELECT
    user_id,
    product_account_id,
    email,
    CAST(is_bot AS BOOLEAN) AS is_bot,
    CAST(is_internal AS BOOLEAN) AS is_internal,
    CAST(created_at AS TIMESTAMP) AS created_at,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_product_users
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_product__events AS
SELECT
    event_id,
    product_account_id,
    user_id,
    event_name,
    feature_key,
    CAST(occurred_at AS TIMESTAMP) AS occurred_at,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_product_events
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY event_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_product__entitlements AS
SELECT
    product_account_id,
    feature_key,
    CAST(effective_from AS DATE) AS effective_from,
    CAST(effective_to AS DATE) AS effective_to,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_product_entitlements
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY product_account_id, feature_key
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_zendesk__tickets AS
SELECT
    ticket_id,
    zendesk_org_id,
    severity,
    status,
    CAST(created_at AS TIMESTAMP) AS created_at,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_zendesk_tickets
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ticket_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

CREATE VIEW stg_zendesk__csat AS
SELECT
    csat_id,
    zendesk_org_id,
    CAST(score AS INTEGER) AS score,
    CAST(responded_at AS TIMESTAMP) AS responded_at,
    CAST(updated_at AS TIMESTAMP) AS updated_at,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_zendesk_csat
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY csat_id
    ORDER BY CAST(updated_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;

-- Stable identity map. There is no display-name column here on purpose.
CREATE VIEW stg_account_crosswalk AS
SELECT
    source_system,
    source_account_id,
    salesforce_account_id,
    CAST(loaded_at AS TIMESTAMP) AS loaded_at,
    CAST(source_row_id AS BIGINT) AS source_row_id
FROM raw_account_crosswalk
WHERE record_label = 'SYNTHETIC'
    AND CAST(loaded_at AS TIMESTAMP) <= (SELECT as_of_timestamp FROM pipeline_run)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY source_system, source_account_id
    ORDER BY CAST(loaded_at AS TIMESTAMP) DESC, CAST(source_row_id AS BIGINT) DESC
) = 1;
