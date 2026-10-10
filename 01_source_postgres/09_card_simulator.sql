-- =====================================================================================
--  Live card activity. Run after 05_dml_simulator_functions.sql.
--  Replaces core.sim_tick so one tick also moves applications, plastic and spend.
-- =====================================================================================
-- Execute the whole script in DBeaver, connected to meridian_core.

CREATE OR REPLACE FUNCTION core.sim_card_applications(p_count int DEFAULT 8) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  INSERT INTO core.customer_features (
      customer_id, segment, risk_rating, age_years, tenure_months,
      estimated_annual_income, avg_monthly_balance, salary_credits_3m, as_of_date
  )
  SELECT c.customer_id, c.segment, c.risk_rating,
         GREATEST(18, EXTRACT(YEAR FROM age(current_date, c.date_of_birth))::int),
         GREATEST(0, (EXTRACT(YEAR FROM age(current_date, c.onboarded_at)) * 12
                   + EXTRACT(MONTH FROM age(current_date, c.onboarded_at)))::int),
         CASE c.segment WHEN 'PRIVATE' THEN 1500000 WHEN 'PREMIUM' THEN 800000 WHEN 'SME' THEN 1000000 ELSE 400000 END,
         20000, 100000, current_date
  FROM core.customers c
  WHERE NOT EXISTS (SELECT 1 FROM core.customer_features f WHERE f.customer_id = c.customer_id);

  INSERT INTO core.card_applications (
      customer_id, product_id, branch_id, channel_code,
      applied_at, decided_at, decision, decision_reason, limit_offered, currency_code,
      segment_at_apply, risk_rating_at_apply, age_years_at_apply, tenure_months_at_apply,
      income_at_apply, balance_at_apply, salary_credits_3m_at_apply
  )
  SELECT
      f.customer_id,
      (SELECT product_id FROM ref.products WHERE product_code = 'CC-GOLD'),
      c.home_branch_id,
      (ARRAY['MOBILE','WEB','BRANCH'])[1 + floor(random()*3)::int],
      clock_timestamp(),
      clock_timestamp(),
      CASE WHEN p >= 0.55 THEN 'APPROVED' ELSE 'REJECTED' END,
      CASE WHEN p >= 0.55 THEN 'APPROVED_POLICY' WHEN f.risk_rating = 'HIGH' THEN 'HIGH_RISK'
           WHEN f.tenure_months < 6 THEN 'THIN_FILE' ELSE 'INSUFFICIENT_INCOME' END,
      CASE WHEN p >= 0.55 THEN round((LEAST(f.estimated_annual_income * 0.25, 500000))::numeric, -2) END,
      'INR',
      f.segment, f.risk_rating, f.age_years, f.tenure_months,
      f.estimated_annual_income, f.avg_monthly_balance, f.salary_credits_3m
  FROM (
      SELECT f.*,
             1.0 / (1.0 + exp(-(core.card_policy_logit(
                 f.estimated_annual_income, f.avg_monthly_balance, f.salary_credits_3m,
                 f.tenure_months, f.age_years, f.risk_rating
             ) + (random() - 0.5) * 0.35))) AS p
      FROM core.customer_features f
      JOIN core.customers c0 ON c0.customer_id = f.customer_id AND c0.country_code = 'IN'
      WHERE NOT EXISTS (
          SELECT 1 FROM core.credit_cards k WHERE k.customer_id = f.customer_id AND k.status = 'ACTIVE'
      )
      ORDER BY random()
      LIMIT p_count
  ) f
  JOIN core.customers c ON c.customer_id = f.customer_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  INSERT INTO core.credit_cards (
      card_last4, customer_id, product_id, branch_id, currency_code,
      credit_limit, current_outstanding, status, opened_date, expiry_date, application_id
  )
  SELECT lpad(floor(random()*10000)::int::text, 4, '0'),
         a.customer_id, a.product_id, a.branch_id, a.currency_code,
         a.limit_offered, 0, 'ACTIVE', current_date, current_date + 1460, a.application_id
  FROM core.card_applications a
  WHERE a.decision = 'APPROVED'
    AND a.decided_at > clock_timestamp() - interval '2 minutes'
    AND NOT EXISTS (SELECT 1 FROM core.credit_cards k WHERE k.application_id = a.application_id);

  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION core.sim_card_authorizations(p_count int DEFAULT 40) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  INSERT INTO core.card_authorizations (
      card_id, customer_id, merchant_id, auth_ts, amount, currency_code,
      entry_mode, card_present, merchant_country, response, fraud_label, fraud_pattern
  )
  SELECT
      c.card_id,
      c.customer_id,
      m.merchant_id,
      clock_timestamp() - (c.r * interval '90 seconds'),
      round((200 + c.r2 * 6000)::numeric, 2),
      c.currency_code,
      CASE WHEN m.is_online THEN 'ECOM' ELSE 'POS' END,
      NOT m.is_online,
      m.country_code,
      'APPROVED',
      false,
      NULL
  FROM (
      SELECT card_id, customer_id, currency_code,
             random() AS r, random() AS r2,
             1 + floor(random() * (SELECT count(*) FROM ref.merchants))::int AS pick
      FROM core.credit_cards
      WHERE status = 'ACTIVE'
      ORDER BY random()
      LIMIT p_count
  ) c
  JOIN (
      SELECT merchant_id, is_online, country_code,
             row_number() OVER (ORDER BY merchant_id) AS rn
      FROM ref.merchants
  ) m ON m.rn = c.pick;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- A short burst the fraud rules should light up within one micro-batch.
CREATE OR REPLACE FUNCTION core.sim_card_fraud_burst() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_card core.credit_cards%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO v_card FROM core.credit_cards WHERE status = 'ACTIVE' ORDER BY random() LIMIT 1;
  IF NOT FOUND THEN RETURN 0; END IF;

  INSERT INTO core.card_authorizations (
      card_id, customer_id, merchant_id, auth_ts, amount, currency_code,
      entry_mode, card_present, merchant_country, response, fraud_label, fraud_pattern
  )
  SELECT v_card.card_id, v_card.customer_id,
         (SELECT merchant_id FROM ref.merchants WHERE merchant_code = 'CROMA'),
         clock_timestamp() - (g * interval '40 seconds'),
         25 + g, v_card.currency_code, 'ECOM', false,
         (SELECT country_code FROM core.customers WHERE customer_id = v_card.customer_id),
         'APPROVED', true, 'VELOCITY'
  FROM generate_series(0, 4) g;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION core.sim_tick(p_txn int DEFAULT 500)
RETURNS TABLE (step text, rows_affected int)
LANGUAGE plpgsql AS $$
BEGIN
  step := 'post_transactions';   rows_affected := core.sim_post_transactions(p_txn); RETURN NEXT;
  step := 'settle_pending';      rows_affected := core.sim_settle_pending();         RETURN NEXT;
  step := 'reverse_random';      rows_affected := core.sim_reverse_random(3);        RETURN NEXT;
  step := 'customer_changes';    rows_affected := core.sim_customer_changes(20);     RETURN NEXT;
  step := 'new_customers';       rows_affected := core.sim_new_customers(5);         RETURN NEXT;
  step := 'account_lifecycle';   rows_affected := core.sim_account_lifecycle(5);     RETURN NEXT;
  step := 'loan_pipeline';       rows_affected := core.sim_loan_pipeline(30);        RETURN NEXT;
  step := 'card_applications';   rows_affected := core.sim_card_applications(6);     RETURN NEXT;
  step := 'card_authorizations'; rows_affected := core.sim_card_authorizations(40);  RETURN NEXT;
  step := 'card_fraud_burst';    rows_affected := core.sim_card_fraud_burst();       RETURN NEXT;
  step := 'fx_tick';             rows_affected := ref.sim_fx_tick();                 RETURN NEXT;
  step := 'hard_deletes';        rows_affected := core.sim_hard_deletes(1);          RETURN NEXT;
  RETURN;
END $$;
