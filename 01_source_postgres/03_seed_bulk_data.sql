-- =====================================================================================
--  Seed: bulk operational data (customers, accounts, holders, transactions, loans)
--
--  Course size, written in the SQL below: 200000 customers and 5 million transactions.
--  For a larger performance-lab load, change both numbers together before executing.
--  5 million transactions takes a few minutes. Execute the whole script in DBeaver.
-- =====================================================================================

-- ------------------------------------------------------------------ customers
TRUNCATE core.customers, core.accounts, core.account_holders, core.transactions, core.loan_applications
  RESTART IDENTITY CASCADE;

WITH first_names AS (
  SELECT ARRAY['Aarav','Vivaan','Aditya','Ananya','Diya','Ishaan','Kavya','Rohan','Priya','Arjun','Sneha','Rahul',
               'Fatima','Omar','Layla','Yusuf','Mariam','Khalid','Oliver','Amelia','Harry','Isla','James','Emily',
               'Liam','Noah','Olivia','Emma','Ava','Sophia','Wei','Mei','Jun','Hui','Kai','Ling'] AS a
),
last_names AS (
  SELECT ARRAY['Sharma','Patel','Khan','Iyer','Reddy','Nair','Mehta','Desai','Gupta','Singh','Verma','Joshi',
               'Al Mansoori','Haddad','Al Falasi','Smith','Jones','Taylor','Brown','Wilson','Johnson','Williams',
               'Garcia','Miller','Davis','Tan','Lim','Lee','Ng','Wong','Goh','Chua'] AS a
),
gen AS (
  SELECT g AS n,
         1 + floor(random() * (SELECT count(*) FROM core.branches))::int AS home_branch_id,
         random() AS r1, random() AS r2, random() AS r3, random() AS r4
  FROM generate_series(1, 200000) AS g
)
INSERT INTO core.customers (customer_number, first_name, last_name, date_of_birth, gender, email, phone,
                            kyc_status, segment, risk_rating, home_branch_id, country_code, city,
                            onboarded_at, created_at, updated_at)
SELECT
  'CIF' || lpad(gen.n::text, 8, '0'),
  fn.a[1 + floor(gen.r1 * array_length(fn.a,1))::int],
  ln.a[1 + floor(gen.r2 * array_length(ln.a,1))::int],
  DATE '1950-01-01' + (gen.r3 * 19000)::int,                            -- 1950..2002
  CASE WHEN gen.r4 < 0.48 THEN 'M' WHEN gen.r4 < 0.97 THEN 'F' ELSE 'O' END,
  lower(fn.a[1 + floor(gen.r1 * array_length(fn.a,1))::int]) || '.' || gen.n || '@example.com',
  '+' || (1000000000 + (gen.r2 * 8999999999)::bigint)::text,
  CASE WHEN gen.r1 < 0.85 THEN 'VERIFIED' WHEN gen.r1 < 0.95 THEN 'PENDING' ELSE 'EXPIRED' END,
  CASE WHEN gen.r2 < 0.70 THEN 'RETAIL' WHEN gen.r2 < 0.90 THEN 'PREMIUM' WHEN gen.r2 < 0.95 THEN 'SME' ELSE 'PRIVATE' END,
  CASE WHEN gen.r3 < 0.75 THEN 'LOW' WHEN gen.r3 < 0.95 THEN 'MEDIUM' ELSE 'HIGH' END,
  b.branch_id,
  b.country_code,
  b.city,
  now() - (gen.r4 * interval '1100 days') - interval '30 days',
  now() - (gen.r4 * interval '1100 days') - interval '30 days',
  now() - (gen.r4 * interval '1100 days') - interval '30 days'
FROM gen
JOIN core.branches b ON b.branch_id = gen.home_branch_id
CROSS JOIN first_names fn
CROSS JOIN last_names ln;

-- ------------------------------------------------------------------ accounts (1-2 per customer, same branch & currency as customer)
INSERT INTO core.accounts (account_number, product_id, branch_id, currency_code, status, opened_date, closed_date,
                           current_balance, credit_limit, interest_rate, created_at, updated_at)
SELECT
  -- deterministic business key: AC + customer id + sequence => the owner is recoverable
  'AC' || lpad(c.customer_id::text, 9, '0') || g,
  p.product_id,
  c.home_branch_id,
  co.currency_code,
  CASE WHEN random() < 0.90 THEN 'ACTIVE' WHEN random() < 0.6 THEN 'DORMANT' WHEN random() < 0.5 THEN 'FROZEN' ELSE 'CLOSED' END,
  (c.onboarded_at + (random() * interval '20 days'))::date,
  NULL,
  0,
  CASE WHEN p.product_type = 'CREDIT_CARD' THEN round((random() * 20000 + 1000)::numeric, -2) END,
  p.base_interest_rate,
  c.onboarded_at + interval '1 day',
  c.onboarded_at + interval '1 day'
FROM core.customers c
JOIN ref.countries co ON co.country_code = c.country_code
CROSS JOIN LATERAL generate_series(1, CASE WHEN c.customer_id % 2 = 0 THEN 2 ELSE 1 END) AS g
JOIN ref.products p
  ON p.product_id = CASE
       WHEN g = 1 THEN 1 + (c.customer_id % 2)                                   -- savings variants
       ELSE (ARRAY[3,4,5,6,7,8])[1 + (c.customer_id % 6)::int]                   -- current / FD / loans / card
     END;

UPDATE core.accounts
SET closed_date = opened_date + (random() * 300)::int
WHERE status = 'CLOSED';

-- ------------------------------------------------------------------ account_holders: primary = owning customer, +10% joint
-- The owner is encoded in account_number (AC + 9-digit customer_id + seq), so recover it with substring().
INSERT INTO core.account_holders (account_id, customer_id, holder_role, added_at, created_at, updated_at)
SELECT a.account_id,
       substring(a.account_number FROM 3 FOR 9)::bigint,
       'PRIMARY', a.created_at, a.created_at, a.created_at
FROM core.accounts a;

-- joint holders: 10% of accounts get a second customer from the same branch
INSERT INTO core.account_holders (account_id, customer_id, holder_role, added_at, created_at, updated_at)
SELECT DISTINCT ON (a.account_id)
       a.account_id, c2.customer_id, 'JOINT', a.created_at + interval '2 days', a.created_at + interval '2 days', a.created_at + interval '2 days'
FROM core.accounts a
JOIN core.account_holders ah ON ah.account_id = a.account_id AND ah.holder_role = 'PRIMARY'
JOIN LATERAL (
  SELECT customer_id FROM core.customers c
  WHERE c.home_branch_id = a.branch_id AND c.customer_id <> ah.customer_id
  ORDER BY c.customer_id LIMIT 1 OFFSET floor(random() * 50)::int
) c2 ON true
WHERE a.account_id % 10 = 0
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ transactions (batched, N million)
-- Batching keeps WAL and memory in check and lets the lesson print progress.
-- The DO block reads this session setting. 5 means 5 million transactions.
SELECT set_config('meridian.txn_millions', '5', false);

DO $$
DECLARE
  v_total    bigint := current_setting('meridian.txn_millions')::int * 1000000;
  v_batch    int    := 500000;
  v_done     bigint := 0;
  v_accounts bigint;
BEGIN
  SELECT count(*) INTO v_accounts FROM core.accounts;

  WHILE v_done < v_total LOOP
    -- LESSON: random() must sit in a per-row SELECT list. An uncorrelated LATERAL (SELECT random())
    -- is legally evaluated ONCE by the planner and every row would get the same value.
    INSERT INTO core.transactions (account_id, transaction_ts, transaction_type, amount, currency_code, channel_id,
                                   branch_id, employee_id, counterparty_account, merchant_category, status,
                                   description, created_at, updated_at)
    WITH base AS (
      SELECT g,
             1 + floor(random() * v_accounts)::bigint      AS account_id,
             now() - (random() * interval '540 days')      AS ts,
             random() AS r_type, random() AS r_ch, random() AS r_status, random() AS r_amt, random() AS r_misc
      FROM generate_series(1, v_batch) AS g
    ),
    typed AS (
      SELECT b.*,
             CASE WHEN r_type < 0.22 THEN 'CARD_PAYMENT'  WHEN r_type < 0.40 THEN 'TRANSFER_OUT'  -- 0.22-0.40 = UPI style
                  WHEN r_type < 0.55 THEN 'WITHDRAWAL'    WHEN r_type < 0.70 THEN 'DEPOSIT'
                  WHEN r_type < 0.80 THEN 'TRANSFER_OUT'  WHEN r_type < 0.88 THEN 'TRANSFER_IN'
                  WHEN r_type < 0.93 THEN 'SALARY_CREDIT' WHEN r_type < 0.96 THEN 'FEE'
                  WHEN r_type < 0.985 THEN 'INTEREST'     ELSE 'LOAN_EMI' END AS transaction_type,
             (r_type >= 0.22 AND r_type < 0.40) AS is_upi
      FROM base b
    ),
    routed AS (
      SELECT t.*,
             CASE WHEN transaction_type IN ('FEE','INTEREST','LOAN_EMI','SALARY_CREDIT') THEN 'SYSTEM'
                  WHEN transaction_type = 'CARD_PAYMENT' THEN 'POS'
                  WHEN is_upi THEN 'UPI'
                  WHEN transaction_type = 'WITHDRAWAL' THEN (ARRAY['ATM','ATM','BRANCH'])[1 + floor(r_ch*3)::int]
                  WHEN transaction_type = 'DEPOSIT'    THEN (ARRAY['BRANCH','ATM','MOBILE'])[1 + floor(r_ch*3)::int]
                  ELSE (ARRAY['MOBILE','NETBANKING'])[1 + floor(r_ch*2)::int] END AS channel_code
      FROM typed t
    )
    SELECT
      a.account_id,
      greatest(r.ts, (a.opened_date + 1)::timestamptz),       -- no activity before the account existed
      r.transaction_type,
      round((power(r.r_amt, 3) * CASE WHEN a.currency_code = 'INR' THEN 200000 ELSE 5000 END + 5)::numeric, 2),
      a.currency_code,
      ch.channel_id,
      CASE WHEN r.channel_code IN ('BRANCH','ATM') THEN a.branch_id END,
      CASE WHEN r.channel_code = 'BRANCH'
           THEN (SELECT e.employee_id FROM core.employees e WHERE e.branch_id = a.branch_id ORDER BY e.employee_id LIMIT 1) END,
      CASE WHEN r.transaction_type IN ('TRANSFER_IN','TRANSFER_OUT')
           THEN 'AC' || lpad((1 + floor(r.r_misc * v_accounts))::text, 10, '0') END,
      CASE WHEN r.transaction_type = 'CARD_PAYMENT'
           THEN (ARRAY['GROCERY','FUEL','DINING','TRAVEL','UTILITIES','ELECTRONICS','HEALTH','ENTERTAINMENT'])[1 + floor(r.r_misc*8)::int] END,
      CASE WHEN r.r_status < 0.96 THEN 'POSTED' WHEN r.r_status < 0.99 THEN 'PENDING' ELSE 'REVERSED' END,
      r.transaction_type || ' via ' || r.channel_code,
      greatest(r.ts, (a.opened_date + 1)::timestamptz),
      greatest(r.ts, (a.opened_date + 1)::timestamptz)
    FROM routed r
    JOIN core.accounts a ON a.account_id = r.account_id
    JOIN ref.channels ch ON ch.channel_code = r.channel_code;

    v_done := v_done + v_batch;
    RAISE NOTICE '% / % transactions inserted (%)', v_done, v_total, clock_timestamp();
  END LOOP;
END $$;

-- ------------------------------------------------------------------ loan applications (accumulating snapshot source)
INSERT INTO core.loan_applications (customer_id, branch_id, product_id, loan_officer_id, amount_requested, amount_approved,
                                    currency_code, status, applied_at, reviewed_at, approved_at, rejected_at,
                                    disbursed_at, closed_at, created_at, updated_at)
SELECT
  c.customer_id,
  c.home_branch_id,
  p.product_id,
  (SELECT e.employee_id FROM core.employees e WHERE e.branch_id = c.home_branch_id AND e.job_title = 'LOAN_OFFICER' LIMIT 1),
  s.amount,
  CASE WHEN s.stage >= 3 THEN round((s.amount * (0.7 + random() * 0.3))::numeric, -2) END,
  co.currency_code,
  CASE s.stage WHEN 1 THEN 'APPLIED' WHEN 2 THEN 'UNDER_REVIEW' WHEN 3 THEN 'APPROVED'
               WHEN 4 THEN 'DISBURSED' WHEN 5 THEN 'CLOSED' ELSE 'REJECTED' END,
  s.applied_at,
  CASE WHEN s.stage >= 2 OR s.stage = 0 THEN s.applied_at + (random() * interval '3 days') END,
  CASE WHEN s.stage >= 3 THEN s.applied_at + interval '3 days' + (random() * interval '7 days') END,
  CASE WHEN s.stage = 0  THEN s.applied_at + interval '2 days' + (random() * interval '5 days') END,
  CASE WHEN s.stage >= 4 THEN s.applied_at + interval '10 days' + (random() * interval '10 days') END,
  CASE WHEN s.stage = 5  THEN s.applied_at + interval '200 days' + (random() * interval '100 days') END,
  s.applied_at, s.applied_at
FROM (
  SELECT customer_id FROM core.customers WHERE customer_id % 4 = 0 LIMIT 60000
) pick
JOIN core.customers c USING (customer_id)
JOIN ref.countries co ON co.country_code = c.country_code
JOIN ref.products p ON p.product_id = (ARRAY[5,6,7])[1 + (c.customer_id % 3)::int]
CROSS JOIN LATERAL (
  SELECT (now() - (random() * interval '500 days')) AS applied_at,
         round((power(random(), 2) * CASE WHEN co.currency_code = 'INR' THEN 5000000 ELSE 80000 END + 1000)::numeric, -2) AS amount,
         floor(random() * 6)::int AS stage                                         -- 0=rejected .. 5=closed
) s;

-- ------------------------------------------------------------------ balances = sum(credits) - sum(debits) of POSTED txns
WITH net AS (
  SELECT account_id,
         sum(CASE WHEN transaction_type IN ('DEPOSIT','TRANSFER_IN','INTEREST','SALARY_CREDIT','REFUND') THEN amount ELSE -amount END) AS bal
  FROM core.transactions
  WHERE status = 'POSTED'
  GROUP BY account_id
)
UPDATE core.accounts a
SET current_balance = net.bal
FROM net
WHERE net.account_id = a.account_id;

ANALYZE;

SELECT 'customers' AS t, count(*) FROM core.customers
UNION ALL SELECT 'accounts', count(*) FROM core.accounts
UNION ALL SELECT 'account_holders', count(*) FROM core.account_holders
UNION ALL SELECT 'transactions', count(*) FROM core.transactions
UNION ALL SELECT 'loan_applications', count(*) FROM core.loan_applications;
