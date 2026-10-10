-- =====================================================================================
--  Seed: reference data, 520 branches, employees, 18 months of FX rates
--  Pure SQL (generate_series + arrays) -> also a lesson in set-based data generation.
--  Idempotent: safe to re-run (ON CONFLICT DO NOTHING / TRUNCATE where appropriate).
-- =====================================================================================
-- Execute the whole script in DBeaver, connected to meridian_core.

BEGIN;

-- ------------------------------------------------------------------ currencies
INSERT INTO ref.currencies (currency_code, currency_name, symbol, minor_units) VALUES
  ('USD','US Dollar','$',2),
  ('INR','Indian Rupee','₹',2),
  ('AED','UAE Dirham','د.إ',2),
  ('GBP','Pound Sterling','£',2),
  ('SGD','Singapore Dollar','S$',2)
ON CONFLICT (currency_code) DO NOTHING;

-- ------------------------------------------------------------------ countries
INSERT INTO ref.countries (country_code, country_name, currency_code, region, timezone) VALUES
  ('IN','India','INR','APAC','Asia/Kolkata'),
  ('AE','United Arab Emirates','AED','MEA','Asia/Dubai'),
  ('GB','United Kingdom','GBP','EUROPE','Europe/London'),
  ('US','United States','USD','AMERICAS','America/New_York'),
  ('SG','Singapore','SGD','APAC','Asia/Singapore')
ON CONFLICT (country_code) DO NOTHING;

-- ------------------------------------------------------------------ channels
INSERT INTO ref.channels (channel_code, channel_name, is_digital) VALUES
  ('BRANCH','Branch counter',false),
  ('ATM','ATM',false),
  ('MOBILE','Mobile app',true),
  ('NETBANKING','Internet banking',true),
  ('UPI','UPI / instant payments',true),
  ('POS','Card at point of sale',true),
  ('SYSTEM','System generated (interest, fees)',true)
ON CONFLICT (channel_code) DO NOTHING;

-- ------------------------------------------------------------------ products
INSERT INTO ref.products (product_code, product_name, product_category, product_type, base_interest_rate) VALUES
  ('SAV-STD','Everyday Savings','DEPOSIT','SAVINGS',0.0350),
  ('SAV-PRM','Premium Savings','DEPOSIT','SAVINGS',0.0425),
  ('CUR-BUS','Business Current Account','DEPOSIT','CURRENT',0.0000),
  ('FD-12','Fixed Deposit 12m','DEPOSIT','FIXED_DEPOSIT',0.0675),
  ('PL-STD','Personal Loan','LOAN','PERSONAL_LOAN',0.1150),
  ('HL-STD','Home Loan','LOAN','HOME_LOAN',0.0825),
  ('AL-STD','Auto Loan','LOAN','AUTO_LOAN',0.0950),
  ('CC-GOLD','Gold Credit Card','CARD','CREDIT_CARD',0.3600)
ON CONFLICT (product_code) DO NOTHING;

-- ------------------------------------------------------------------ branches (520)
-- Distribution: IN 300, AE 60, GB 60, US 60, SG 40
TRUNCATE core.branches RESTART IDENTITY CASCADE;

WITH plan AS (
  SELECT * FROM (VALUES
    ('IN', 300, ARRAY['Mumbai','Delhi','Bengaluru','Pune','Hyderabad','Chennai','Kolkata','Ahmedabad','Jaipur','Lucknow','Surat','Nagpur','Indore','Kochi','Chandigarh']),
    ('AE',  60, ARRAY['Dubai','Abu Dhabi','Sharjah','Ajman','Al Ain','Ras Al Khaimah']),
    ('GB',  60, ARRAY['London','Manchester','Birmingham','Leeds','Glasgow','Edinburgh','Bristol','Liverpool']),
    ('US',  60, ARRAY['New York','Jersey City','Chicago','Houston','San Jose','Dallas','Atlanta','Seattle']),
    ('SG',  40, ARRAY['Singapore'])
  ) AS t(country_code, n, cities)
),
rows_ AS (
  SELECT p.country_code,
         p.cities,
         g AS seq
  FROM plan p
  CROSS JOIN LATERAL generate_series(1, p.n) AS g
)
INSERT INTO core.branches (branch_code, branch_name, country_code, city, state_region, branch_type, opened_date, status, created_at, updated_at)
SELECT
  r.country_code || '-' || upper(left(regexp_replace(c.city,'\s','','g'),3)) || '-' || lpad(r.seq::text, 4, '0')  AS branch_code,
  c.city || ' ' || CASE WHEN r.seq % 7 = 0 THEN 'Premium Centre' ELSE 'Branch ' || r.seq END                  AS branch_name,
  r.country_code,
  c.city,
  NULL,
  CASE WHEN r.seq % 7 = 0 THEN 'PREMIUM'
       WHEN r.seq % 11 = 0 THEN 'DIGITAL_HUB'
       WHEN r.country_code = 'IN' AND r.seq % 5 = 0 THEN 'RURAL'
       ELSE 'FULL_SERVICE' END                                                                                   AS branch_type,
  DATE '2005-01-01' + (random() * 7000)::int                                                                     AS opened_date,
  'OPEN',
  now() - interval '18 months', now() - interval '18 months'
FROM rows_ r
CROSS JOIN LATERAL (SELECT r.cities[1 + ((r.seq - 1) % array_length(r.cities, 1))] AS city) c;

-- ------------------------------------------------------------------ employees (~6 per branch)
TRUNCATE core.employees RESTART IDENTITY CASCADE;

WITH first_names AS (
  SELECT ARRAY['Aarav','Vivaan','Aditya','Ananya','Diya','Ishaan','Kavya','Rohan','Fatima','Omar','Layla','Yusuf',
               'Oliver','Amelia','Harry','Isla','James','Emily','Liam','Noah','Olivia','Emma','Wei','Mei','Jun','Hui'] AS a
),
last_names AS (
  SELECT ARRAY['Sharma','Patel','Khan','Iyer','Reddy','Nair','Al Mansoori','Haddad','Smith','Jones','Taylor','Brown',
               'Johnson','Williams','Garcia','Tan','Lim','Lee','Ng','Wong','Mehta','Desai','Gupta','Singh'] AS a
)
INSERT INTO core.employees (employee_code, branch_id, full_name, job_title, hire_date, is_active, created_at, updated_at)
SELECT
  'EMP' || lpad(row_number() OVER ()::text, 6, '0'),
  b.branch_id,
  fn.a[1 + floor(random() * array_length(fn.a,1))::int] || ' ' || ln.a[1 + floor(random() * array_length(ln.a,1))::int],
  CASE g WHEN 1 THEN 'BRANCH_MANAGER' WHEN 2 THEN 'RELATIONSHIP_MANAGER' WHEN 3 THEN 'LOAN_OFFICER'
         WHEN 4 THEN 'OPERATIONS' ELSE 'TELLER' END,
  GREATEST(b.opened_date, DATE '2010-01-01') + (random() * 3000)::int,
  true,
  now() - interval '18 months', now() - interval '18 months'
FROM core.branches b
CROSS JOIN generate_series(1, 6) AS g
CROSS JOIN first_names fn
CROSS JOIN last_names ln;

-- ------------------------------------------------------------------ FX rates: 18 months, business days only, random walk
-- Teaching point: a random walk in SQL = exp( running SUM of small log-returns ) * starting rate.
TRUNCATE ref.fx_rates RESTART IDENTITY;

WITH days AS (
  SELECT d::date AS rate_date
  FROM generate_series(current_date - interval '1100 days', current_date, interval '1 day') AS d
  WHERE extract(isodow FROM d) < 6                       -- Mon..Fri only -> gaps on weekends
),
pairs AS (
  SELECT * FROM (VALUES ('INR', 0.0120), ('AED', 0.2723), ('GBP', 1.2700), ('SGD', 0.7450)) AS p(from_currency, start_rate)
),
walk AS (
  SELECT d.rate_date,
         p.from_currency,
         p.start_rate,
         (random() - 0.5) * 0.006 AS log_return               -- ±0.3% daily noise
  FROM days d CROSS JOIN pairs p
)
INSERT INTO ref.fx_rates (rate_date, from_currency, to_currency, rate, source, created_at, updated_at)
SELECT rate_date,
       from_currency,
       'USD',
       round((start_rate * exp(sum(log_return) OVER (PARTITION BY from_currency ORDER BY rate_date)))::numeric, 8),
       'TREASURY_CLOSE',
       (rate_date + time '17:30') AT TIME ZONE 'UTC',
       (rate_date + time '17:30') AT TIME ZONE 'UTC'
FROM walk;

COMMIT;

SELECT 'currencies' AS t, count(*) FROM ref.currencies
UNION ALL SELECT 'countries', count(*) FROM ref.countries
UNION ALL SELECT 'channels', count(*) FROM ref.channels
UNION ALL SELECT 'products', count(*) FROM ref.products
UNION ALL SELECT 'branches', count(*) FROM core.branches
UNION ALL SELECT 'employees', count(*) FROM core.employees
UNION ALL SELECT 'fx_rates', count(*) FROM ref.fx_rates;
