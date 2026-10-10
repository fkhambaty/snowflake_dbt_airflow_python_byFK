-- =====================================================================================
--  Credit-card history: merchants, sale calendar, offers, applications, plastic, spend.
--  Run after 03_seed_bulk_data.sql and 07_ddl_cards.sql.
--
--  Course size, written in the SQL below: 12000 applications, 15 authorizations per card.
--  Execute the whole script in DBeaver, connected to meridian_core.
--
--  Applications span the customer's life (up to ~3 years, bounded by FX history).
--  The approve/reject label is the policy function plus a little noise — the model in
--  09_decisioning_python has to recover that policy, not memorise a flag.
--  About 1% of authorizations are injected fraud patterns the rules are designed to see.
-- =====================================================================================
DO $$ BEGIN
  IF (SELECT count(*) FROM core.customers) < 100 THEN
    RAISE EXCEPTION 'Seed customers first (03_seed_bulk_data.sql)';
  END IF;
END $$;

-- ------------------------------------------------------------------ reference
INSERT INTO ref.products (product_code, product_name, product_category, product_type, base_interest_rate) VALUES
  ('CC-PLAT','Platinum Credit Card','CARD','CREDIT_CARD',0.3000),
  ('CC-SEC','Secured Credit Card','CARD','CREDIT_CARD',0.2400)
ON CONFLICT (product_code) DO NOTHING;

INSERT INTO ref.channels (channel_code, channel_name, is_digital) VALUES
  ('ECOM','Online card checkout', true)
ON CONFLICT (channel_code) DO NOTHING;

TRUNCATE
  core.card_authorizations,
  core.credit_cards,
  core.card_applications,
  core.customer_features
RESTART IDENTITY CASCADE;

TRUNCATE ref.sale_events, ref.offer_catalog RESTART IDENTITY CASCADE;
DELETE FROM ref.merchants;

INSERT INTO ref.merchants (merchant_code, merchant_name, category_group, marketplace, country_code, is_online) VALUES
  ('FLIPKART',  'Flipkart',                 'ECOM_MARKETPLACE', 'FLIPKART', 'IN', true),
  ('AMAZON_IN', 'Amazon.in',                'ECOM_MARKETPLACE', 'AMAZON',   'IN', true),
  ('AMAZON_AE', 'Amazon.ae',                'ECOM_MARKETPLACE', 'AMAZON',   'AE', true),
  ('AMAZON_US', 'Amazon.com',               'ECOM_MARKETPLACE', 'AMAZON',   'US', true),
  ('MYNTRA',    'Myntra',                   'ECOM_MARKETPLACE', NULL,       'IN', true),
  ('BIGBAZAAR', 'Big Bazaar',               'GROCERY',          NULL,       'IN', false),
  ('DMART',     'DMart',                    'GROCERY',          NULL,       'IN', false),
  ('SHELL_IN',  'Shell',                    'FUEL',             NULL,       'IN', false),
  ('INDIGO',    'IndiGo',                   'TRAVEL',           NULL,       'IN', true),
  ('SWIGGY',    'Swiggy',                   'DINING',           NULL,       'IN', true),
  ('CROMA',     'Croma',                    'ELECTRONICS',      NULL,       'IN', false),
  ('ATM_NCR',   'NCR ATM cash',             'CASH',             NULL,       'IN', false),
  ('CARREFOUR', 'Carrefour',                'GROCERY',          NULL,       'AE', false),
  ('TESCO',     'Tesco',                    'GROCERY',          NULL,       'GB', false),
  ('WALMART',   'Walmart',                  'GROCERY',          NULL,       'US', false);

-- Fixed public-style windows so the demo does not depend on today's news.
INSERT INTO ref.sale_events (marketplace, event_name, country_code, starts_on, ends_on) VALUES
  ('FLIPKART','Big Billion Days','IN','2024-09-27','2024-10-06'),
  ('AMAZON',  'Great Indian Festival','IN','2024-09-27','2024-10-06'),
  ('FLIPKART','Big Billion Days','IN','2025-09-23','2025-10-02'),
  ('AMAZON',  'Great Indian Festival','IN','2025-09-23','2025-10-06'),
  ('AMAZON',  'Prime Day','US','2025-07-15','2025-07-16'),
  ('FLIPKART','Big Billion Days','IN','2026-09-23','2026-10-02'),
  ('AMAZON',  'Great Indian Festival','IN','2026-09-23','2026-10-06'),
  ('FLIPKART','Big Billion Days','IN','2027-09-24','2027-10-03'),
  ('AMAZON',  'Great Indian Festival','IN','2027-09-24','2027-10-07');

INSERT INTO ref.offer_catalog (offer_code, offer_name, offer_family, marketplace, cashback_rate, description) VALUES
  ('ACQ_FEE_WAIVE',      'First-year fee waived',          'ACQUISITION', NULL,       0.0000, 'Acquisition offer for customers who look like approved cardholders and do not have a card yet.'),
  ('FLIPKART_CASHBACK_5','5% Flipkart cashback in sale',   'USAGE',       'FLIPKART', 0.0500, 'Timed to Big Billion Days. Only customers whose own spend leans Flipkart.'),
  ('AMAZON_CASHBACK_5',  '5% Amazon cashback in sale',     'USAGE',       'AMAZON',   0.0500, 'Timed to Great Indian Festival / Prime Day. Same rule, other marketplace.'),
  ('LIMIT_REVIEW',       'Limit increase review',          'LIMIT',       NULL,       0.0000, 'Low utilisation, clean recent authorizations, long tenure. A human still confirms.'),
  ('NO_OFFER',           'Do not contact',                'SUPPRESS',    NULL,       0.0000, 'Fraud review or high risk. Suppression is an offer decision too.');

-- ------------------------------------------------------------------ feature snapshot (one row per customer)
INSERT INTO core.customer_features (
    customer_id, segment, risk_rating, age_years, tenure_months,
    estimated_annual_income, avg_monthly_balance, salary_credits_3m, as_of_date
)
SELECT
    c.customer_id,
    c.segment,
    c.risk_rating,
    GREATEST(18, EXTRACT(YEAR FROM age(current_date, c.date_of_birth))::int),
    GREATEST(0, (EXTRACT(YEAR FROM age(current_date, c.onboarded_at)) * 12
              + EXTRACT(MONTH FROM age(current_date, c.onboarded_at)))::int),
    round((
        CASE c.segment
            WHEN 'PRIVATE' THEN 1800000
            WHEN 'PREMIUM' THEN 900000
            WHEN 'SME'     THEN 1200000
            ELSE 420000
        END * (0.55 + random())
    )::numeric, 2),
    round((COALESCE(bal.avg_balance, 25000) * (0.5 + random()))::numeric, 2),
    0,  -- filled next so it can depend on income
    current_date
FROM core.customers c
LEFT JOIN (
    SELECT h.customer_id, avg(a.current_balance) AS avg_balance
    FROM core.account_holders h
    JOIN core.accounts a ON a.account_id = h.account_id
    WHERE h.holder_role = 'PRIMARY'
    GROUP BY h.customer_id
) bal ON bal.customer_id = c.customer_id;

UPDATE core.customer_features
SET salary_credits_3m = round((estimated_annual_income / 4.0 * (0.75 + random() * 0.4))::numeric, 2);

-- ------------------------------------------------------------------ applications (policy + noise)
INSERT INTO core.card_applications (
    customer_id, product_id, branch_id, channel_code,
    applied_at, decided_at, decision, decision_reason, limit_offered, currency_code,
    segment_at_apply, risk_rating_at_apply, age_years_at_apply, tenure_months_at_apply,
    income_at_apply, balance_at_apply, salary_credits_3m_at_apply,
    created_at, updated_at
)
WITH products AS (
    SELECT
        max(product_id) FILTER (WHERE product_code = 'CC-GOLD') AS gold_id,
        max(product_id) FILTER (WHERE product_code = 'CC-PLAT') AS plat_id,
        max(product_id) FILTER (WHERE product_code = 'CC-SEC')  AS sec_id
    FROM ref.products
),
feat AS (
    SELECT
        f.*,
        c.home_branch_id,
        c.onboarded_at,
        c.date_of_birth,
        row_number() OVER (ORDER BY f.customer_id) AS rn,
        count(*) OVER () AS n
    FROM core.customer_features f
    JOIN core.customers c ON c.customer_id = f.customer_id
    WHERE c.country_code = 'IN'
      AND c.onboarded_at < current_timestamp - interval '30 days'
),
gen AS (
    SELECT
        g AS g,
        1 + floor(random() * (SELECT max(n) FROM feat))::int AS rn,
        random() AS r_noise,
        random() AS r_when,
        random() AS r_prod,
        random() AS r_channel
    FROM generate_series(1, 12000) AS g
),
draft AS (
    SELECT
        f.customer_id,
        CASE WHEN g.r_prod < 0.62 THEN p.gold_id WHEN g.r_prod < 0.88 THEN p.plat_id ELSE p.sec_id END AS product_id,
        f.home_branch_id,
        CASE WHEN g.r_channel < 0.45 THEN 'MOBILE' WHEN g.r_channel < 0.70 THEN 'WEB' ELSE 'BRANCH' END AS channel_code,
        f.onboarded_at + (g.r_when * EXTRACT(EPOCH FROM (current_timestamp - interval '2 days' - f.onboarded_at)) * interval '1 second') AS applied_at,
        f.segment,
        f.risk_rating,
        f.date_of_birth,
        f.onboarded_at,
        f.estimated_annual_income,
        f.avg_monthly_balance,
        f.salary_credits_3m,
        g.r_noise
    FROM gen g
    JOIN feat f ON f.rn = g.rn
    CROSS JOIN products p
),
scored AS (
    SELECT
        d.*,
        GREATEST(18, EXTRACT(YEAR FROM age(d.applied_at, d.date_of_birth))::int) AS age_at,
        GREATEST(0, (EXTRACT(YEAR FROM age(d.applied_at, d.onboarded_at)) * 12
                  + EXTRACT(MONTH FROM age(d.applied_at, d.onboarded_at)))::int) AS tenure_at,
        core.card_policy_logit(
            d.estimated_annual_income, d.avg_monthly_balance, d.salary_credits_3m,
            GREATEST(0, (EXTRACT(YEAR FROM age(d.applied_at, d.onboarded_at)) * 12
                      + EXTRACT(MONTH FROM age(d.applied_at, d.onboarded_at)))::int),
            GREATEST(18, EXTRACT(YEAR FROM age(d.applied_at, d.date_of_birth))::int),
            d.risk_rating
        ) + (d.r_noise - 0.5) * 0.35 AS noisy_logit
    FROM draft d
)
SELECT
    customer_id,
    product_id,
    home_branch_id,
    channel_code,
    applied_at,
    applied_at + interval '6 hours',
    CASE WHEN 1.0 / (1.0 + exp(-noisy_logit)) >= 0.55 THEN 'APPROVED' ELSE 'REJECTED' END,
    CASE
        WHEN 1.0 / (1.0 + exp(-noisy_logit)) >= 0.55 THEN 'APPROVED_POLICY'
        WHEN risk_rating = 'HIGH' THEN 'HIGH_RISK'
        WHEN tenure_at < 6 THEN 'THIN_FILE'
        ELSE 'INSUFFICIENT_INCOME'
    END,
    CASE
        WHEN 1.0 / (1.0 + exp(-noisy_logit)) >= 0.55
        THEN round((LEAST(estimated_annual_income * 0.25, 500000))::numeric, -2)
    END,
    'INR',
    segment,
    risk_rating,
    age_at,
    tenure_at,
    estimated_annual_income,
    avg_monthly_balance,
    salary_credits_3m,
    applied_at,
    applied_at + interval '6 hours'
FROM scored;

-- ------------------------------------------------------------------ plastic for approved customers
INSERT INTO core.credit_cards (
    card_last4, customer_id, product_id, branch_id, currency_code,
    credit_limit, current_outstanding, status, opened_date, expiry_date, application_id,
    created_at, updated_at
)
SELECT
    lpad(floor(random() * 10000)::int::text, 4, '0'),
    a.customer_id,
    a.product_id,
    a.branch_id,
    a.currency_code,
    a.limit_offered,
    round((a.limit_offered * random() * 0.45)::numeric, 2),
    CASE WHEN random() < 0.01 THEN 'BLOCKED' ELSE 'ACTIVE' END,
    a.decided_at::date,
    (a.decided_at::date + interval '4 years')::date,
    a.application_id,
    a.decided_at,
    a.decided_at
FROM (
    SELECT DISTINCT ON (customer_id) *
    FROM core.card_applications
    WHERE decision = 'APPROVED' AND limit_offered IS NOT NULL
    ORDER BY customer_id, decided_at DESC
) a;

-- ------------------------------------------------------------------ authorizations, with a sale-window bias toward marketplaces
INSERT INTO core.card_authorizations (
    card_id, customer_id, merchant_id, auth_ts, amount, currency_code,
    entry_mode, card_present, merchant_country, response, decline_reason,
    fraud_label, fraud_pattern, created_at, updated_at
)
WITH merchants AS (
    SELECT
        max(merchant_id) FILTER (WHERE merchant_code = 'FLIPKART')  AS flipkart_id,
        max(merchant_id) FILTER (WHERE merchant_code = 'AMAZON_IN') AS amazon_id
    FROM ref.merchants
),
offline AS (
    SELECT merchant_id, country_code, is_online,
           row_number() OVER (ORDER BY merchant_id) AS rn,
           count(*) OVER () AS n
    FROM ref.merchants
    WHERE marketplace IS NULL
),
base AS (
    SELECT
        c.card_id,
        c.customer_id,
        c.credit_limit,
        c.opened_date,
        c.currency_code,
        cu.country_code AS home_country,
        random() AS r_day,
        random() AS r_merch,
        random() AS r_amt,
        random() AS r_fraud,
        random() AS r_decline
    FROM core.credit_cards c
    JOIN core.customers cu ON cu.customer_id = c.customer_id
    CROSS JOIN generate_series(1, 15) AS g
    WHERE c.opened_date < current_date
),
timed AS (
    SELECT
        b.*,
        (b.opened_date + (b.r_day * (current_date - b.opened_date))::int) AS auth_date
    FROM base b
),
sale AS (
    SELECT t.*,
           EXISTS (
               SELECT 1 FROM ref.sale_events e
               WHERE e.country_code = 'IN'
                 AND t.auth_date BETWEEN e.starts_on AND e.ends_on
           ) AS in_sale
    FROM timed t
)
SELECT
    s.card_id,
    s.customer_id,
    CASE
        WHEN s.in_sale AND s.r_merch < 0.38 THEN m.flipkart_id
        WHEN s.in_sale AND s.r_merch < 0.76 THEN m.amazon_id
        WHEN s.r_merch < 0.16 THEN m.flipkart_id
        WHEN s.r_merch < 0.30 THEN m.amazon_id
        ELSE o.merchant_id
    END,
    (s.auth_date + time '12:00') AT TIME ZONE 'UTC'
        + (s.r_amt * interval '10 hours'),
    CASE
        WHEN s.r_fraud >= 0.012 AND s.r_fraud < 0.022 THEN round((s.credit_limit * 0.72)::numeric, 2)
        WHEN s.in_sale AND s.r_merch < 0.76 THEN round((800 + s.r_amt * 14000)::numeric, 2)
        ELSE round((150 + s.r_amt * 4500)::numeric, 2)
    END,
    s.currency_code,
    CASE
        WHEN s.in_sale OR s.r_merch < 0.30 THEN 'ECOM'
        WHEN s.r_merch > 0.97 THEN 'ATM'
        WHEN s.r_merch > 0.85 THEN 'CONTACTLESS'
        ELSE 'POS'
    END,
    NOT (s.in_sale OR s.r_merch < 0.30 OR s.r_fraud < 0.012),
    CASE WHEN s.r_fraud < 0.012 THEN 'US' ELSE s.home_country END,
    CASE
        WHEN s.r_fraud >= 0.012 AND s.r_fraud < 0.022 THEN 'DECLINED'
        WHEN s.r_decline < 0.03 THEN 'DECLINED'
        ELSE 'APPROVED'
    END,
    CASE
        WHEN s.r_fraud >= 0.012 AND s.r_fraud < 0.022 THEN 'OVER_LIMIT'
        WHEN s.r_decline < 0.03 THEN 'INSUFFICIENT_LIMIT'
    END,
    s.r_fraud < 0.022,
    CASE
        WHEN s.r_fraud < 0.012 THEN 'GEO_MISMATCH'
        WHEN s.r_fraud < 0.022 THEN 'HIGH_AMOUNT'
    END,
    (s.auth_date + time '12:00') AT TIME ZONE 'UTC',
    (s.auth_date + time '12:00') AT TIME ZONE 'UTC'
FROM sale s
CROSS JOIN merchants m
JOIN offline o ON o.rn = 1 + floor(s.r_merch * o.n)::int % o.n
WHERE s.auth_date >= s.opened_date;

-- Velocity clusters: 5 auths inside a few minutes, on 250 cards. The window rule should catch these.
INSERT INTO core.card_authorizations (
    card_id, customer_id, merchant_id, auth_ts, amount, currency_code,
    entry_mode, card_present, merchant_country, response,
    fraud_label, fraud_pattern, created_at, updated_at
)
SELECT
    c.card_id,
    c.customer_id,
    (SELECT merchant_id FROM ref.merchants WHERE merchant_code = 'CROMA'),
    GREATEST(c.opened_date + 1, current_date - 40)::timestamp
        + (g * interval '70 seconds')
        + ((c.card_id % 50) * interval '1 hour'),
    40 + g,
    c.currency_code,
    'ECOM',
    false,
    cu.country_code,
    'APPROVED',
    true,
    'VELOCITY',
    current_timestamp - interval '20 days',
    current_timestamp - interval '20 days'
FROM (
    SELECT * FROM core.credit_cards WHERE status = 'ACTIVE' ORDER BY card_id LIMIT 80
) c
JOIN core.customers cu ON cu.customer_id = c.customer_id
CROSS JOIN generate_series(0, 4) AS g;

-- Card-testing clusters: several ₹1 authorizations a minute apart. One ₹1 row is not a pattern.
INSERT INTO core.card_authorizations (
    card_id, customer_id, merchant_id, auth_ts, amount, currency_code,
    entry_mode, card_present, merchant_country, response,
    fraud_label, fraud_pattern, created_at, updated_at
)
SELECT
    c.card_id, c.customer_id,
    (SELECT merchant_id FROM ref.merchants WHERE merchant_code = 'CROMA'),
    GREATEST(c.opened_date + 2, current_date - 25)::timestamp + (g * interval '45 seconds'),
    1.00, c.currency_code, 'ECOM', false, cu.country_code, 'APPROVED',
    true, 'CARD_TESTING',
    GREATEST(c.opened_date + 2, current_date - 25)::timestamp,
    GREATEST(c.opened_date + 2, current_date - 25)::timestamp
FROM (
    SELECT * FROM core.credit_cards WHERE status = 'ACTIVE' ORDER BY card_id DESC LIMIT 60
) c
JOIN core.customers cu ON cu.customer_id = c.customer_id
CROSS JOIN generate_series(0, 3) AS g;

-- Guaranteed sale-window spend, both marketplaces, only while the card was already open.
-- Random dates rarely land inside a 10-day festival; the campaign chart should not depend on that.
INSERT INTO core.card_authorizations (
    card_id, customer_id, merchant_id, auth_ts, amount, currency_code,
    entry_mode, card_present, merchant_country, response,
    fraud_label, created_at, updated_at
)
SELECT
    c.card_id,
    c.customer_id,
    CASE e.marketplace
        WHEN 'FLIPKART' THEN (SELECT merchant_id FROM ref.merchants WHERE merchant_code = 'FLIPKART')
        ELSE (SELECT merchant_id FROM ref.merchants WHERE merchant_code = 'AMAZON_IN')
    END,
    ((e.starts_on + g) + time '15:00') AT TIME ZONE 'UTC',
    round((12000 + (g * 5000))::numeric, 2),
    c.currency_code,
    'ECOM',
    false,
    'IN',
    'APPROVED',
    false,
    ((e.starts_on + g) + time '15:00') AT TIME ZONE 'UTC',
    ((e.starts_on + g) + time '15:00') AT TIME ZONE 'UTC'
FROM core.credit_cards c
JOIN ref.sale_events e
  ON e.country_code = 'IN'
 AND e.starts_on >= c.opened_date
 AND e.ends_on <= current_date
CROSS JOIN generate_series(0, 2) AS g
WHERE c.status = 'ACTIVE'
  AND c.card_id % 4 = 0;

SELECT 'customer_features' AS entity, count(*) FROM core.customer_features
UNION ALL SELECT 'card_applications', count(*) FROM core.card_applications
UNION ALL SELECT 'card_applications_approved', count(*) FROM core.card_applications WHERE decision = 'APPROVED'
UNION ALL SELECT 'credit_cards', count(*) FROM core.credit_cards
UNION ALL SELECT 'card_authorizations', count(*) FROM core.card_authorizations
UNION ALL SELECT 'fraud_labeled', count(*) FROM core.card_authorizations WHERE fraud_label;
