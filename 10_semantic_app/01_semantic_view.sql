-- Semantic view over the gold layer. Cortex Analyst answers English questions against it.
-- Run as MERIDIAN_TRANSFORMER after dbt build. Region limits: 10_semantic_app/README.md.
--
-- customer_id joins to who the customer is TODAY (DIM_CUSTOMER_CURRENT).
-- customer_key is the SCD2 version at the event. The instructions tell Analyst
-- to use DIM_CUSTOMER on customer_key only when the user says "at the time".

CREATE OR REPLACE SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK
  TABLES (
    transactions AS MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS
      PRIMARY KEY (transaction_id)
      WITH SYNONYMS = ('payments', 'ledger')
      COMMENT = 'One row per account transaction. Amounts in local currency and USD.',
    customers AS MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER_CURRENT
      PRIMARY KEY (customer_id)
      WITH SYNONYMS = ('clients')
      COMMENT = 'Who the customer is today, not the historical version.',
    branches AS MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH
      PRIMARY KEY (branch_id),
    card_authorizations AS MERIDIAN_ANALYTICS.MARTS.FCT_CARD_AUTHORIZATIONS
      PRIMARY KEY (authorization_id)
      WITH SYNONYMS = ('card spend', 'card swipes')
      COMMENT = 'One card authorization. Use is_rule_suspect for fraud. Never use fraud_label.',
    merchants AS MERIDIAN_ANALYTICS.MARTS.DIM_MERCHANT
      PRIMARY KEY (merchant_id),
    card_applications AS MERIDIAN_ANALYTICS.MARTS.FCT_CARD_APPLICATIONS
      PRIMARY KEY (application_id)
      WITH SYNONYMS = ('credit card applications'),
    offers AS MERIDIAN_ANALYTICS.MARTS.FCT_NEXT_BEST_OFFER
      PRIMARY KEY (customer_id)
      WITH SYNONYMS = ('campaign', 'who to contact')
  )
  RELATIONSHIPS (
    transactions_to_customers AS transactions (customer_id) REFERENCES customers,
    transactions_to_branches AS transactions (branch_id) REFERENCES branches,
    authorizations_to_customers AS card_authorizations (customer_id) REFERENCES customers,
    authorizations_to_merchants AS card_authorizations (merchant_id) REFERENCES merchants,
    applications_to_customers AS card_applications (customer_id) REFERENCES customers,
    offers_to_customers AS offers (customer_id) REFERENCES customers
  )
  FACTS (
    transactions.amount_reporting AS transactions.amount_reporting
      COMMENT = 'USD at the transaction-date FX rate',
    transactions.signed_amount_reporting AS transactions.signed_amount_reporting
      COMMENT = 'Positive in, negative out, USD',
    card_authorizations.amount_reporting AS card_authorizations.amount_reporting,
    card_applications.limit_offered AS card_applications.limit_offered
  )
  DIMENSIONS (
    customers.segment AS customers.segment WITH SYNONYMS = ('customer segment'),
    customers.risk_rating AS customers.risk_rating,
    customers.country_code AS customers.country_code,
    branches.country_code AS branches.country_code WITH SYNONYMS = ('branch country'),
    branches.city AS branches.city,
    transactions.transaction_date AS transactions.transaction_date,
    transactions.status AS transactions.status COMMENT = 'Default business questions to POSTED',
    transactions.transaction_type AS transactions.transaction_type,
    card_authorizations.auth_date AS card_authorizations.auth_date,
    card_authorizations.response AS card_authorizations.response,
    card_authorizations.marketplace AS card_authorizations.marketplace WITH SYNONYMS = ('Flipkart or Amazon'),
    card_authorizations.sale_event_name AS card_authorizations.sale_event_name,
    card_authorizations.is_rule_suspect AS card_authorizations.is_rule_suspect,
    card_applications.decision AS card_applications.decision,
    card_applications.segment_at_apply AS card_applications.segment_at_apply,
    offers.offer_name AS offers.offer_name,
    offers.reason AS offers.reason
  )
  METRICS (
    transactions.net_flow_usd AS SUM(transactions.signed_amount_reporting),
    transactions.transaction_count AS COUNT(transactions.transaction_id),
    card_authorizations.card_spend_usd AS SUM(card_authorizations.amount_reporting),
    card_authorizations.suspected_fraud_count AS COUNT(CASE WHEN card_authorizations.is_rule_suspect THEN 1 END),
    card_applications.approval_rate AS AVG(IFF(card_applications.decision = 'APPROVED', 1, 0)),
    card_applications.application_count AS COUNT(card_applications.application_id),
    offers.customers_to_contact AS COUNT(offers.customer_id)
  )
  COMMENT = 'Meridian Bank gold layer for Cortex Analyst. Row access policies already remove rows the caller cannot see.'
  AI_SQL_GENERATION 'Reporting currency is USD. Default transactions to status = POSTED. Default card authorizations to response = APPROVED unless the user asks about declines or fraud. Segment and risk on customers are current. If the user says at the time, join MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER on customer_key. Never use fraud_label. Do not sum balances across months. Marketplace is FLIPKART or AMAZON. A customer missing from offers was suppressed or did not qualify. Do not add a filter to imitate row-level security and do not try to turn a policy off. The caller may be one customer, one branch, or the whole bank; the policy decides which rows come back.'
  AI_VERIFIED_QUERIES (
    card_spend_in_sales AS (
      QUESTION 'How much approved card spend did we have on Flipkart and Amazon during sale events?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT marketplace, sale_event_name, SUM(amount_reporting) AS card_spend_usd FROM MERIDIAN_ANALYTICS.MARTS.FCT_CARD_AUTHORIZATIONS WHERE response = ''APPROVED'' AND marketplace IS NOT NULL AND sale_event_name IS NOT NULL GROUP BY 1, 2 ORDER BY 1, 2'
    ),
    approval_rate_by_segment AS (
      QUESTION 'What is the credit card approval rate by the segment the customer had when they applied?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT segment_at_apply, COUNT(*) AS applications, AVG(IFF(decision = ''APPROVED'', 1, 0)) AS approval_rate FROM MERIDIAN_ANALYTICS.MARTS.FCT_CARD_APPLICATIONS GROUP BY 1 ORDER BY 3 DESC'
    ),
    who_to_contact AS (
      QUESTION 'Who should we contact with a card offer before the next sale, and why?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT offer_name, sale_event_name, reason, COUNT(*) AS customers FROM MERIDIAN_ANALYTICS.MARTS.FCT_NEXT_BEST_OFFER GROUP BY 1, 2, 3 ORDER BY customers DESC'
    ),
    fraud_queue AS (
      QUESTION 'How many suspected fraudulent card authorizations did the rules flag?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT COUNT(*) AS suspected_authorizations FROM MERIDIAN_ANALYTICS.MARTS.FCT_CARD_AUTHORIZATIONS WHERE is_rule_suspect'
    )
  );

-- Personas need the view; the row access policies on its tables decide the rows.
GRANT SELECT ON SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK TO ROLE MERIDIAN_ANALYST;
GRANT SELECT ON SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK TO ROLE MERIDIAN_APP;
GRANT SELECT ON SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK TO ROLE MERIDIAN_CEO;
GRANT SELECT ON SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK TO ROLE MERIDIAN_BRANCH_MANAGER;
GRANT SELECT ON SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK TO ROLE MERIDIAN_STAFF;
GRANT SELECT ON SEMANTIC VIEW MERIDIAN_ANALYTICS.MARTS.SV_MERIDIAN_BANK TO ROLE MERIDIAN_CUSTOMER;
