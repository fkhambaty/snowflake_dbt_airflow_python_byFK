-- =====================================================================================
--  MERIDIAN BANK  |  Credit cards
--  Run after 01_ddl_core_schema.sql and before 04_cdc_triggers.sql (re-run triggers
--  so the new tables bump updated_at and log deletes).
--
--  What this is
--    Cards are a second business process on the same customers: applications (approve /
--    reject), plastic, authorizations at merchants, and a score table the model writes
--    back into. Flipkart and Amazon appear as merchants plus a sale calendar — we do
--    not have those marketplaces' shopper data, only our own card spend at them.
--
--  What this is not
--    No full PAN, no CVV, no real bureau file. card_last4 is a random mask.
--    fraud_label is a synthetic ground truth for measuring detection. It is not a
--    feature, and a real bank would not have it at authorization time.
-- =====================================================================================
-- Execute the whole script in DBeaver, connected to meridian_core.

-- ------------------------------------------------------------------ products already allow CREDIT_CARD
-- Extra card products are inserted by 08_seed_cards.sql

-- ------------------------------------------------------------------ merchants (conformed dimension upstream)
CREATE TABLE IF NOT EXISTS ref.merchants (
    merchant_id     SERIAL       PRIMARY KEY,
    merchant_code   TEXT         NOT NULL UNIQUE,
    merchant_name   TEXT         NOT NULL,
    category_group  TEXT         NOT NULL CHECK (category_group IN
                      ('ECOM_MARKETPLACE','GROCERY','FUEL','TRAVEL','DINING','ELECTRONICS','CASH','OTHER')),
    marketplace     TEXT         CHECK (marketplace IN ('FLIPKART','AMAZON')),
    country_code    CHAR(2)      NOT NULL REFERENCES ref.countries(country_code),
    is_online       BOOLEAN      NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Public sale windows. Marketing timing is "our spend lifts here", not their audience.
CREATE TABLE IF NOT EXISTS ref.sale_events (
    sale_event_id   SERIAL       PRIMARY KEY,
    marketplace     TEXT         NOT NULL CHECK (marketplace IN ('FLIPKART','AMAZON')),
    event_name      TEXT         NOT NULL,
    country_code    CHAR(2)      NOT NULL REFERENCES ref.countries(country_code),
    starts_on       DATE         NOT NULL,
    ends_on         DATE         NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (ends_on >= starts_on),
    UNIQUE (marketplace, event_name, country_code, starts_on)
);

CREATE TABLE IF NOT EXISTS ref.offer_catalog (
    offer_code      TEXT         PRIMARY KEY,
    offer_name      TEXT         NOT NULL,
    offer_family    TEXT         NOT NULL CHECK (offer_family IN ('ACQUISITION','USAGE','LIMIT','SUPPRESS')),
    marketplace     TEXT         CHECK (marketplace IN ('FLIPKART','AMAZON')),
    cashback_rate   NUMERIC(6,4) NOT NULL DEFAULT 0,
    description     TEXT         NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- One row per customer: the attributes a decision can legally see.
-- Applications COPY these at apply time so later changes cannot rewrite history.
CREATE TABLE IF NOT EXISTS core.customer_features (
    customer_id            BIGINT       PRIMARY KEY REFERENCES core.customers(customer_id),
    segment                TEXT         NOT NULL,
    risk_rating            TEXT         NOT NULL,
    age_years              INT          NOT NULL,
    tenure_months          INT          NOT NULL,
    estimated_annual_income NUMERIC(18,2) NOT NULL,
    avg_monthly_balance    NUMERIC(18,2) NOT NULL,
    salary_credits_3m      NUMERIC(18,2) NOT NULL,
    as_of_date             DATE         NOT NULL,
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.card_applications (
    application_id          BIGSERIAL    PRIMARY KEY,
    customer_id             BIGINT       NOT NULL REFERENCES core.customers(customer_id),
    product_id              INT          NOT NULL REFERENCES ref.products(product_id),
    branch_id               INT          NOT NULL REFERENCES core.branches(branch_id),
    channel_code            TEXT         NOT NULL CHECK (channel_code IN ('BRANCH','MOBILE','WEB')),
    applied_at              TIMESTAMPTZ  NOT NULL,
    decided_at              TIMESTAMPTZ,
    decision                TEXT         NOT NULL CHECK (decision IN ('APPROVED','REJECTED','PENDING')),
    decision_reason         TEXT,
    limit_offered           NUMERIC(18,2),
    currency_code           CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    -- frozen at decision time (point-in-time). Do not recompute from today's customer row.
    segment_at_apply        TEXT         NOT NULL,
    risk_rating_at_apply    TEXT         NOT NULL,
    age_years_at_apply      INT          NOT NULL,
    tenure_months_at_apply  INT          NOT NULL,
    income_at_apply         NUMERIC(18,2) NOT NULL,
    balance_at_apply        NUMERIC(18,2) NOT NULL,
    salary_credits_3m_at_apply NUMERIC(18,2) NOT NULL,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.credit_cards (
    card_id              BIGSERIAL    PRIMARY KEY,
    card_last4           CHAR(4)      NOT NULL,
    customer_id          BIGINT       NOT NULL REFERENCES core.customers(customer_id),
    product_id           INT          NOT NULL REFERENCES ref.products(product_id),
    branch_id            INT          NOT NULL REFERENCES core.branches(branch_id),
    currency_code        CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    credit_limit         NUMERIC(18,2) NOT NULL CHECK (credit_limit > 0),
    current_outstanding  NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (current_outstanding >= 0),
    status               TEXT         NOT NULL CHECK (status IN ('ACTIVE','BLOCKED','CLOSED')),
    opened_date          DATE         NOT NULL,
    expiry_date          DATE         NOT NULL,
    application_id       BIGINT       REFERENCES core.card_applications(application_id),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.card_authorizations (
    authorization_id  BIGSERIAL    PRIMARY KEY,
    card_id           BIGINT       NOT NULL REFERENCES core.credit_cards(card_id),
    customer_id       BIGINT       NOT NULL REFERENCES core.customers(customer_id),
    merchant_id       INT          NOT NULL REFERENCES ref.merchants(merchant_id),
    auth_ts           TIMESTAMPTZ  NOT NULL,
    amount            NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    currency_code     CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    entry_mode        TEXT         NOT NULL CHECK (entry_mode IN ('POS','ECOM','CONTACTLESS','ATM')),
    card_present      BOOLEAN      NOT NULL,
    merchant_country  CHAR(2)      NOT NULL,
    response          TEXT         NOT NULL CHECK (response IN ('APPROVED','DECLINED')),
    decline_reason    TEXT,
    -- Synthetic label for evaluation ONLY. Never a model feature. Never available live.
    fraud_label       BOOLEAN      NOT NULL DEFAULT FALSE,
    fraud_pattern     TEXT         CHECK (fraud_pattern IN ('VELOCITY','GEO_MISMATCH','HIGH_AMOUNT','CARD_TESTING')),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Model scores are NOT stored here. They are analytical output, so they land in
-- Snowflake (MERIDIAN_RAW.ML). Writing them into the system of record would make the
-- warehouse a source of the OLTP. See 00_architecture/adr/0005.

CREATE INDEX IF NOT EXISTS ix_card_auth_updated_at ON core.card_authorizations (updated_at);
CREATE INDEX IF NOT EXISTS ix_card_auth_card_ts    ON core.card_authorizations (card_id, auth_ts);
CREATE INDEX IF NOT EXISTS ix_card_apps_customer   ON core.card_applications (customer_id);
CREATE INDEX IF NOT EXISTS ix_cards_customer       ON core.credit_cards (customer_id);
-- -------------------------------------------------------------------------------------
-- The underwriting policy, in one deterministic function.
-- The seed, the simulator and the dbt fallback macro all use these weights.
-- Noise is added by the caller so this function stays pure and testable.
-- logit is log-odds; probability = 1 / (1 + exp(-logit)). Approve at probability >= 0.55.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.card_policy_logit(
    p_income  NUMERIC,
    p_balance NUMERIC,
    p_salary  NUMERIC,
    p_tenure  INT,
    p_age     INT,
    p_risk    TEXT
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT (
        -1.1
        + 1.3 * LEAST(p_income  / 2000000.0, 2)
        + 0.8 * LEAST(p_balance / 200000.0,  2)
        + 0.9 * LEAST(p_salary  / 300000.0,  2)
        + 0.6 * (CASE WHEN p_tenure >= 12 THEN 1 WHEN p_tenure >= 6 THEN 0.5 ELSE 0 END)
        - (CASE p_risk WHEN 'HIGH' THEN 1.2 WHEN 'MEDIUM' THEN 0.4 ELSE 0 END)
        - (CASE WHEN p_age < 23 THEN 0.4 ELSE 0 END)
    )::NUMERIC
$$;

COMMENT ON FUNCTION core.card_policy_logit IS
  'Explainable credit policy. Weights are teaching values, not a production scorecard.';
COMMENT ON COLUMN core.card_authorizations.fraud_label IS
  'Synthetic ground truth injected by the seed. Evaluation only — never a feature.';
