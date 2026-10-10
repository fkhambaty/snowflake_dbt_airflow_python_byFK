-- =====================================================================================
--  DML simulator: makes the OLTP system "alive" so the pipeline has something to ingest
--  every few minutes. Each function is an isolated, re-runnable unit of realistic change.
--
--  Drive it from DBeaver:  SELECT * FROM core.sim_tick(500);
--  or from Python:         02_ingestion_python/simulate_activity.py
--
--  Every function exercises a specific warehouse concept:
--    sim_post_transactions  -> INSERTs            (fact rows)
--    sim_settle_pending     -> UPDATE status      (mutable fact -> incremental MERGE needed)
--    sim_reverse_random     -> UPDATE status      (negative adjustments)
--    sim_customer_changes   -> UPDATE attributes  (SCD2 on dim_customer)
--    sim_account_lifecycle  -> INSERT+UPDATE      (new dim members, SCD2 on dim_account)
--    sim_new_customers      -> INSERT             (late-arriving dimension rows)
--    sim_loan_pipeline      -> UPDATE milestones  (accumulating snapshot fact)
--    sim_fx_tick            -> INSERT/UPDATE      (today's rate, rate corrections)
--    sim_hard_deletes       -> DELETE             (delete propagation via cdc.deleted_records)
-- =====================================================================================
-- Execute the whole script in DBeaver, connected to meridian_core.

-- ------------------------------------------------------------------ transactions
CREATE OR REPLACE FUNCTION core.sim_post_transactions(p_count int DEFAULT 500) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_inserted int;
  v_max_account bigint;
BEGIN
  SELECT max(account_id) INTO v_max_account FROM core.accounts;

  WITH base AS (
    SELECT 1 + floor(random() * v_max_account)::bigint AS account_id,
           random() AS r_type, random() AS r_ch, random() AS r_status, random() AS r_amt, random() AS r_misc
    FROM generate_series(1, p_count)
  ),
  typed AS (
    SELECT b.*,
           CASE WHEN r_type < 0.25 THEN 'CARD_PAYMENT' WHEN r_type < 0.45 THEN 'TRANSFER_OUT'
                WHEN r_type < 0.58 THEN 'WITHDRAWAL'   WHEN r_type < 0.72 THEN 'DEPOSIT'
                WHEN r_type < 0.85 THEN 'TRANSFER_IN'  WHEN r_type < 0.92 THEN 'SALARY_CREDIT'
                WHEN r_type < 0.96 THEN 'FEE'          WHEN r_type < 0.99 THEN 'REFUND' ELSE 'LOAN_EMI' END AS transaction_type,
           (r_type >= 0.25 AND r_type < 0.45) AS is_upi
    FROM base b
  ),
  routed AS (
    SELECT t.*,
           CASE WHEN transaction_type IN ('FEE','LOAN_EMI','SALARY_CREDIT') THEN 'SYSTEM'
                WHEN transaction_type = 'CARD_PAYMENT' THEN 'POS'
                WHEN is_upi THEN 'UPI'
                WHEN transaction_type = 'WITHDRAWAL' THEN (ARRAY['ATM','ATM','BRANCH'])[1 + floor(r_ch*3)::int]
                WHEN transaction_type = 'DEPOSIT'    THEN (ARRAY['BRANCH','ATM','MOBILE'])[1 + floor(r_ch*3)::int]
                ELSE (ARRAY['MOBILE','NETBANKING'])[1 + floor(r_ch*2)::int] END AS channel_code
    FROM typed t
  ),
  ins AS (
    INSERT INTO core.transactions (account_id, transaction_ts, transaction_type, amount, currency_code, channel_id,
                                   branch_id, employee_id, counterparty_account, merchant_category, status, description)
    SELECT a.account_id,
           clock_timestamp() - (r.r_misc * interval '90 seconds'),          -- slight jitter: events are never perfectly ordered
           r.transaction_type,
           round((power(r.r_amt, 3) * CASE WHEN a.currency_code = 'INR' THEN 200000 ELSE 5000 END + 5)::numeric, 2),
           a.currency_code,
           ch.channel_id,
           CASE WHEN r.channel_code IN ('BRANCH','ATM') THEN a.branch_id END,
           CASE WHEN r.channel_code = 'BRANCH'
                THEN (SELECT e.employee_id FROM core.employees e WHERE e.branch_id = a.branch_id ORDER BY random() LIMIT 1) END,
           CASE WHEN r.transaction_type IN ('TRANSFER_IN','TRANSFER_OUT') THEN 'AC' || lpad((1 + floor(r.r_misc * v_max_account))::text, 10, '0') END,
           CASE WHEN r.transaction_type = 'CARD_PAYMENT'
                THEN (ARRAY['GROCERY','FUEL','DINING','TRAVEL','UTILITIES','ELECTRONICS','HEALTH','ENTERTAINMENT'])[1 + floor(r.r_misc*8)::int] END,
           CASE WHEN r.r_status < 0.80 THEN 'POSTED' ELSE 'PENDING' END,  -- 20% land as PENDING and settle later
           r.transaction_type || ' via ' || r.channel_code
    FROM routed r
    JOIN core.accounts a ON a.account_id = r.account_id AND a.status = 'ACTIVE'
    JOIN ref.channels ch ON ch.channel_code = r.channel_code
    RETURNING account_id, transaction_type, amount, status
  ),
  -- keep OLTP balances consistent for POSTED rows (data-modifying CTEs all run exactly once)
  upd AS (
    UPDATE core.accounts a
    SET current_balance = a.current_balance + d.delta
    FROM (
      SELECT account_id,
             sum(CASE WHEN transaction_type IN ('DEPOSIT','TRANSFER_IN','INTEREST','SALARY_CREDIT','REFUND') THEN amount ELSE -amount END) AS delta
      FROM ins WHERE status = 'POSTED' GROUP BY account_id
    ) d
    WHERE d.account_id = a.account_id
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM ins;

  RETURN v_inserted;
END $$;

-- ------------------------------------------------------------------ settle PENDING -> POSTED after 2 minutes
CREATE OR REPLACE FUNCTION core.sim_settle_pending() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  WITH settled AS (
    UPDATE core.transactions
    SET status = 'POSTED'
    WHERE status = 'PENDING' AND transaction_ts < clock_timestamp() - interval '2 minutes'
    RETURNING account_id, transaction_type, amount
  ),
  upd AS (
    UPDATE core.accounts a
    SET current_balance = a.current_balance + d.delta
    FROM (
      SELECT account_id,
             sum(CASE WHEN transaction_type IN ('DEPOSIT','TRANSFER_IN','INTEREST','SALARY_CREDIT','REFUND') THEN amount ELSE -amount END) AS delta
      FROM settled GROUP BY account_id
    ) d
    WHERE d.account_id = a.account_id
    RETURNING 1
  )
  SELECT count(*) INTO v_n FROM settled;
  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ reverse a few recent POSTED transactions
CREATE OR REPLACE FUNCTION core.sim_reverse_random(p_count int DEFAULT 5) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  UPDATE core.transactions t
  SET status = 'REVERSED', description = description || ' [REVERSED]'
  WHERE t.transaction_id IN (
    SELECT transaction_id FROM core.transactions
    WHERE status = 'POSTED' AND transaction_ts > clock_timestamp() - interval '1 hour'
    ORDER BY random() LIMIT p_count
  );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ customers change (SCD2 fodder)
CREATE OR REPLACE FUNCTION core.sim_customer_changes(p_count int DEFAULT 20) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  UPDATE core.customers c
  SET segment     = CASE WHEN random() < 0.5 THEN (ARRAY['RETAIL','PREMIUM','PRIVATE','SME'])[1 + floor(random()*4)::int] ELSE c.segment END,
      kyc_status  = CASE WHEN random() < 0.4 THEN (ARRAY['PENDING','VERIFIED','EXPIRED'])[1 + floor(random()*3)::int] ELSE c.kyc_status END,
      risk_rating = CASE WHEN random() < 0.3 THEN (ARRAY['LOW','MEDIUM','HIGH'])[1 + floor(random()*3)::int] ELSE c.risk_rating END,
      email       = CASE WHEN random() < 0.1 THEN lower(c.first_name) || '.' || c.customer_id || '.new@example.com' ELSE c.email END
  WHERE c.customer_id IN (SELECT customer_id FROM core.customers TABLESAMPLE SYSTEM (1) LIMIT p_count);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ new customers (late-arriving dims)
CREATE OR REPLACE FUNCTION core.sim_new_customers(p_count int DEFAULT 10) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int; v_start bigint;
BEGIN
  SELECT coalesce(max(customer_id), 0) INTO v_start FROM core.customers;
  INSERT INTO core.customers (customer_number, first_name, last_name, date_of_birth, gender, email, phone, kyc_status,
                              segment, risk_rating, home_branch_id, country_code, city, onboarded_at)
  SELECT 'CIF' || lpad((v_start + pick.g)::text, 8, '0'),
         (ARRAY['Aarav','Ananya','Omar','Layla','Oliver','Amelia','Wei','Mei'])[1 + floor(random()*8)::int],
         (ARRAY['Sharma','Khan','Haddad','Smith','Tan','Lim','Patel','Reddy'])[1 + floor(random()*8)::int],
         DATE '1960-01-01' + (random() * 15000)::int,
         (ARRAY['M','F'])[1 + floor(random()*2)::int],
         'new.customer.' || (v_start + pick.g) || '@example.com',
         '+' || (1000000000 + (random() * 8999999999)::bigint)::text,
         'PENDING', 'RETAIL', 'LOW', b.branch_id, b.country_code, b.city, clock_timestamp()
  FROM (
    SELECT g, 1 + floor(random() * (SELECT max(branch_id) FROM core.branches))::int AS branch_id
    FROM generate_series(1, p_count) g
  ) pick
  JOIN core.branches b ON b.branch_id = pick.branch_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ accounts: open new, close/dormant some
CREATE OR REPLACE FUNCTION core.sim_account_lifecycle(p_count int DEFAULT 10) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_new int; v_upd int;
BEGIN
  -- open new savings accounts for recent customers
  WITH recent AS (
    SELECT c.customer_id, c.home_branch_id, co.currency_code
    FROM core.customers c JOIN ref.countries co USING (country_code)
    WHERE c.onboarded_at > clock_timestamp() - interval '1 day'
      AND NOT EXISTS (SELECT 1 FROM core.account_holders ah WHERE ah.customer_id = c.customer_id)
    LIMIT p_count
  ),
  ins AS (
    INSERT INTO core.accounts (account_number, product_id, branch_id, currency_code, status, opened_date)
    SELECT 'AC' || lpad(customer_id::text, 9, '0') || '1', 1, home_branch_id, currency_code, 'ACTIVE', current_date
    FROM recent
    RETURNING account_id, substring(account_number FROM 3 FOR 9)::bigint AS customer_id
  )
  INSERT INTO core.account_holders (account_id, customer_id, holder_role)
  SELECT account_id, customer_id, 'PRIMARY' FROM ins;
  GET DIAGNOSTICS v_new = ROW_COUNT;

  -- lifecycle changes on existing accounts
  UPDATE core.accounts a
  SET status = CASE WHEN random() < 0.6 THEN 'DORMANT' WHEN random() < 0.5 THEN 'FROZEN' ELSE 'CLOSED' END,
      closed_date = CASE WHEN random() < 0.2 THEN current_date END
  WHERE a.account_id IN (SELECT account_id FROM core.accounts TABLESAMPLE SYSTEM (1) WHERE status = 'ACTIVE' LIMIT p_count);
  GET DIAGNOSTICS v_upd = ROW_COUNT;

  -- fix inconsistent combos the random update may have created
  UPDATE core.accounts SET closed_date = NULL WHERE status <> 'CLOSED' AND closed_date IS NOT NULL;
  UPDATE core.accounts SET closed_date = current_date WHERE status = 'CLOSED' AND closed_date IS NULL;

  RETURN v_new + v_upd;
END $$;

-- ------------------------------------------------------------------ loan pipeline: advance milestones
CREATE OR REPLACE FUNCTION core.sim_loan_pipeline(p_count int DEFAULT 30) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int := 0; v_tmp int;
BEGIN
  -- new applications
  INSERT INTO core.loan_applications (customer_id, branch_id, product_id, loan_officer_id, amount_requested, currency_code, status, applied_at)
  SELECT c.customer_id, c.home_branch_id, (ARRAY[5,6,7])[1 + floor(random()*3)::int],
         (SELECT e.employee_id FROM core.employees e WHERE e.branch_id = c.home_branch_id AND e.job_title = 'LOAN_OFFICER' LIMIT 1),
         round((power(random(),2) * CASE WHEN co.currency_code = 'INR' THEN 5000000 ELSE 80000 END + 1000)::numeric, -2),
         co.currency_code, 'APPLIED', clock_timestamp()
  FROM core.customers c JOIN ref.countries co USING (country_code)
  WHERE c.customer_id IN (SELECT customer_id FROM core.customers TABLESAMPLE SYSTEM (1) LIMIT p_count / 3);
  GET DIAGNOSTICS v_tmp = ROW_COUNT; v_n := v_n + v_tmp;

  UPDATE core.loan_applications SET status = 'UNDER_REVIEW', reviewed_at = clock_timestamp()
  WHERE application_id IN (SELECT application_id FROM core.loan_applications WHERE status = 'APPLIED' ORDER BY applied_at LIMIT p_count / 3);
  GET DIAGNOSTICS v_tmp = ROW_COUNT; v_n := v_n + v_tmp;

  UPDATE core.loan_applications
  SET status = CASE WHEN random() < 0.75 THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id IN (SELECT application_id FROM core.loan_applications WHERE status = 'UNDER_REVIEW' ORDER BY reviewed_at LIMIT p_count / 3);
  UPDATE core.loan_applications SET approved_at = clock_timestamp(), amount_approved = round((amount_requested * (0.7 + random()*0.3))::numeric, -2)
  WHERE status = 'APPROVED' AND approved_at IS NULL;
  UPDATE core.loan_applications SET rejected_at = clock_timestamp() WHERE status = 'REJECTED' AND rejected_at IS NULL;
  GET DIAGNOSTICS v_tmp = ROW_COUNT; v_n := v_n + v_tmp;

  UPDATE core.loan_applications SET status = 'DISBURSED', disbursed_at = clock_timestamp()
  WHERE application_id IN (SELECT application_id FROM core.loan_applications WHERE status = 'APPROVED' ORDER BY approved_at LIMIT p_count / 4);
  GET DIAGNOSTICS v_tmp = ROW_COUNT; v_n := v_n + v_tmp;

  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ FX: today's rate + occasional correction of yesterday
CREATE OR REPLACE FUNCTION ref.sim_fx_tick() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int := 0; v_tmp int;
BEGIN
  IF extract(isodow FROM current_date) < 6 THEN
    INSERT INTO ref.fx_rates (rate_date, from_currency, to_currency, rate, source)
    SELECT current_date, from_currency, 'USD',
           round((rate * (1 + (random() - 0.5) * 0.006))::numeric, 8), 'TREASURY_CLOSE'
    FROM (
      SELECT DISTINCT ON (from_currency) from_currency, rate
      FROM ref.fx_rates WHERE rate_date < current_date
      ORDER BY from_currency, rate_date DESC
    ) latest
    ON CONFLICT (rate_date, from_currency, to_currency) DO NOTHING;
    GET DIAGNOSTICS v_tmp = ROW_COUNT; v_n := v_n + v_tmp;
  END IF;

  -- 5% chance treasury restates yesterday's close (tests that the warehouse picks up UPDATEs on a "static" table)
  IF random() < 0.05 THEN
    UPDATE ref.fx_rates SET rate = round((rate * 1.0001)::numeric, 8), source = 'TREASURY_RESTATED'
    WHERE rate_date = (SELECT max(rate_date) FROM ref.fx_rates WHERE rate_date < current_date);
    GET DIAGNOSTICS v_tmp = ROW_COUNT; v_n := v_n + v_tmp;
  END IF;
  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ hard deletes (rare, but they happen)
CREATE OR REPLACE FUNCTION core.sim_hard_deletes(p_count int DEFAULT 2) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM core.transactions
  WHERE transaction_id IN (
    SELECT transaction_id FROM core.transactions
    WHERE status = 'PENDING' AND transaction_ts > clock_timestamp() - interval '30 minutes'
    ORDER BY random() LIMIT p_count
  );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ------------------------------------------------------------------ one tick = one slice of bank life
CREATE OR REPLACE FUNCTION core.sim_tick(p_txn int DEFAULT 500)
RETURNS TABLE (step text, rows_affected int)
LANGUAGE plpgsql AS $$
BEGIN
  step := 'post_transactions';  rows_affected := core.sim_post_transactions(p_txn); RETURN NEXT;
  step := 'settle_pending';     rows_affected := core.sim_settle_pending();         RETURN NEXT;
  step := 'reverse_random';     rows_affected := core.sim_reverse_random(3);        RETURN NEXT;
  step := 'customer_changes';   rows_affected := core.sim_customer_changes(20);     RETURN NEXT;
  step := 'new_customers';      rows_affected := core.sim_new_customers(5);         RETURN NEXT;
  step := 'account_lifecycle';  rows_affected := core.sim_account_lifecycle(5);     RETURN NEXT;
  step := 'loan_pipeline';      rows_affected := core.sim_loan_pipeline(30);        RETURN NEXT;
  step := 'fx_tick';            rows_affected := ref.sim_fx_tick();                 RETURN NEXT;
  step := 'hard_deletes';       rows_affected := core.sim_hard_deletes(1);          RETURN NEXT;
  RETURN;
END $$;

-- Try it:
-- SELECT * FROM core.sim_tick(500);
-- \watch 5
