-- =====================================================================================
--  SQL LESSONS on the live OLTP data (Episode 1, second half)
--  Each block = one concept + the interview question it answers.
--  In DBeaver, select one block and execute it. Then read the result before the next block.
-- =====================================================================================

-- L01  JOIN types: why LEFT JOIN + WHERE on the right table silently becomes an INNER JOIN
--      Q: "Find branches with zero transactions this month."
SELECT b.branch_code, count(t.transaction_id) AS txns
FROM core.branches b
LEFT JOIN core.transactions t
       ON t.branch_id = b.branch_id
      AND t.transaction_ts >= date_trunc('month', now())      -- filter belongs in ON, not WHERE
GROUP BY b.branch_code
HAVING count(t.transaction_id) = 0
ORDER BY b.branch_code
LIMIT 20;

-- L02  Aggregates with conditional logic (FILTER is cleaner than CASE inside SUM)
--      Q: "Deposits vs withdrawals per channel, last 7 days."
SELECT c.channel_code,
       count(*)                                                         AS txns,
       sum(t.amount) FILTER (WHERE t.transaction_type = 'DEPOSIT')     AS deposits,
       sum(t.amount) FILTER (WHERE t.transaction_type = 'WITHDRAWAL')  AS withdrawals,
       round(avg(t.amount), 2)                                          AS avg_amount
FROM core.transactions t
JOIN ref.channels c USING (channel_id)
WHERE t.transaction_ts >= now() - interval '7 days'
  AND t.status = 'POSTED'
GROUP BY c.channel_code
ORDER BY txns DESC;

-- L03  Window functions I: running balance (the statement-of-account query)
--      Q: "Show the running balance for an account."
SELECT t.transaction_id,
       t.transaction_ts,
       t.transaction_type,
       CASE WHEN t.transaction_type IN ('DEPOSIT','TRANSFER_IN','INTEREST','SALARY_CREDIT','REFUND') THEN t.amount ELSE -t.amount END AS signed_amount,
       sum(CASE WHEN t.transaction_type IN ('DEPOSIT','TRANSFER_IN','INTEREST','SALARY_CREDIT','REFUND') THEN t.amount ELSE -t.amount END)
         OVER (PARTITION BY t.account_id ORDER BY t.transaction_ts, t.transaction_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_balance
FROM core.transactions t
WHERE t.account_id = 42 AND t.status = 'POSTED'
ORDER BY t.transaction_ts;

-- L04  Window functions II: ranking and top-N per group
--      Q: "Top 3 customers by deposits in each country."
WITH deposits AS (
  SELECT c.country_code, c.customer_id, c.first_name || ' ' || c.last_name AS customer, sum(t.amount) AS total
  FROM core.transactions t
  JOIN core.account_holders ah ON ah.account_id = t.account_id AND ah.holder_role = 'PRIMARY'
  JOIN core.customers c ON c.customer_id = ah.customer_id
  WHERE t.transaction_type = 'DEPOSIT' AND t.status = 'POSTED'
    AND t.transaction_ts >= now() - interval '90 days'
  GROUP BY 1,2,3
)
SELECT *
FROM (
  SELECT d.*, dense_rank() OVER (PARTITION BY country_code ORDER BY total DESC) AS rnk
  FROM deposits d
) x
WHERE rnk <= 3
ORDER BY country_code, rnk;
--  Interview follow-up: ROW_NUMBER vs RANK vs DENSE_RANK -> ties behaviour.

-- L05  Window functions III: LAG for "days since previous transaction" (churn signal)
SELECT account_id, transaction_ts,
       transaction_ts - lag(transaction_ts) OVER (PARTITION BY account_id ORDER BY transaction_ts) AS gap
FROM core.transactions
WHERE account_id IN (42, 43)
ORDER BY account_id, transaction_ts;

-- L06  Gaps & islands: forward-fill FX for weekends using a date spine + LEFT JOIN + window
--      (This exact logic is rebuilt in dbt as int_fx_rates_daily_filled.)
WITH spine AS (
  SELECT d::date AS rate_date FROM generate_series(current_date - 30, current_date, interval '1 day') d
),
grid AS (
  SELECT s.rate_date, c.from_currency
  FROM spine s CROSS JOIN (SELECT DISTINCT from_currency FROM ref.fx_rates) c
),
joined AS (
  SELECT g.rate_date, g.from_currency, r.rate,
         count(r.rate) OVER (PARTITION BY g.from_currency ORDER BY g.rate_date) AS grp   -- increments only when a real rate exists
  FROM grid g LEFT JOIN ref.fx_rates r ON r.rate_date = g.rate_date AND r.from_currency = g.from_currency
)
SELECT rate_date, from_currency,
       rate,
       first_value(rate) OVER (PARTITION BY from_currency, grp ORDER BY rate_date) AS rate_filled,
       rate IS NULL AS was_filled
FROM joined
ORDER BY from_currency, rate_date;

-- L07  EXISTS vs IN vs JOIN for "customers who never used mobile"
SELECT count(*)
FROM core.customers c
WHERE NOT EXISTS (
  SELECT 1
  FROM core.account_holders ah
  JOIN core.transactions t ON t.account_id = ah.account_id
  JOIN ref.channels ch ON ch.channel_id = t.channel_id AND ch.channel_code = 'MOBILE'
  WHERE ah.customer_id = c.customer_id
);
--  NOT IN with NULLs returns NOTHING - classic trap. Show it:
SELECT 1 WHERE 1 NOT IN (2, NULL);   -- zero rows!

-- L08  NULL semantics and COUNT
SELECT count(*)            AS all_rows,
       count(branch_id)    AS rows_with_branch,         -- digital channels have NULL branch
       count(DISTINCT branch_id) AS distinct_branches
FROM core.transactions
WHERE transaction_ts >= now() - interval '1 day';

-- L09  Timezones: TIMESTAMPTZ is an instant; display depends on session
SHOW timezone;
SELECT now(), now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'Asia/Kolkata';
SET timezone = 'UTC';   -- what the ingestion job does

-- L10  EXPLAIN: read a plan before you "optimise"
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM core.transactions WHERE updated_at > now() - interval '5 minutes';
--  -> "Seq Scan on transactions" over millions of rows. Fixed in 06_performance_lab/01.

-- L11  Recursive CTE: org chart style - branch -> employees -> who reports to the manager
--      (demo on a hierarchy generated on the fly)
WITH RECURSIVE n AS (
  SELECT 1 AS lvl, 1 AS id
  UNION ALL
  SELECT lvl + 1, id * 2 FROM n WHERE lvl < 5
)
SELECT * FROM n;

-- L12  Data-quality queries you will later turn into dbt tests
SELECT 'accounts_without_primary_holder' AS check_name, count(*) FROM core.accounts a
WHERE NOT EXISTS (SELECT 1 FROM core.account_holders ah WHERE ah.account_id = a.account_id AND ah.holder_role = 'PRIMARY')
UNION ALL
SELECT 'txn_currency_mismatch', count(*) FROM core.transactions t JOIN core.accounts a USING (account_id)
WHERE t.currency_code <> a.currency_code
UNION ALL
SELECT 'closed_before_opened', count(*) FROM core.accounts WHERE closed_date < opened_date;
