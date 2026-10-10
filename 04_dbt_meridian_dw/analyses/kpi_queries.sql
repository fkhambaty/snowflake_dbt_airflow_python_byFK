-- Analyses are compiled (dbt compile) but never run by dbt. They document how the marts are
-- meant to be queried - paste the compiled SQL into Snowsight for the dashboard episode.

-- 1. Group-wide net flow per month in reporting currency, by region
select d.year_month, b.region,
       sum(f.net_flow_reporting)       as net_flow_usd,
       sum(f.fee_income_reporting)     as fee_income_usd,
       sum(f.transaction_count)        as txns
from {{ ref('agg_branch_daily_performance') }} f
join {{ ref('dim_date') }}   d on d.date_key = f.date_key
join {{ ref('dim_branch') }} b on b.branch_key = f.branch_key
group by 1, 2
order by 1, 2;

-- 2. Deposit book at month end (stock) - compare the two conversion methods
select snapshot_date,
       sum(closing_balance_reporting_at_period_end_rate) as book_usd_period_end_rate,
       sum(closing_balance_reporting_at_txn_rates)       as book_usd_txn_rates,
       sum(closing_balance_reporting_at_period_end_rate) - sum(closing_balance_reporting_at_txn_rates) as fx_translation_effect
from {{ ref('fct_monthly_account_balance') }}
group by 1
order by 1;

-- 3. SCD2 in action: deposits by the customer's segment AT THE TIME of the transaction
select c.segment, d.year_month, sum(f.amount_reporting) as deposits_usd
from {{ ref('fct_transactions') }} f
join {{ ref('dim_customer') }} c on c.customer_key = f.customer_key      -- version-specific key => point-in-time truth
join {{ ref('dim_date') }}     d on d.date_key = f.date_key
where f.transaction_type = 'DEPOSIT' and f.status = 'POSTED'
group by 1, 2
order by 2, 1;

-- 4. Same question with CURRENT segment (Type 1 view over a Type 2 dim) - compare the numbers!
select cur.segment, d.year_month, sum(f.amount_reporting) as deposits_usd
from {{ ref('fct_transactions') }} f
join {{ ref('dim_customer') }} v   on v.customer_key = f.customer_key
join {{ ref('dim_customer') }} cur on cur.customer_id = v.customer_id and cur.is_current
join {{ ref('dim_date') }}     d   on d.date_key = f.date_key
where f.transaction_type = 'DEPOSIT' and f.status = 'POSTED'
group by 1, 2
order by 2, 1;

-- 5. Bridge table: allocated deposits per customer (totals reconcile to the fact)
select cust.customer_id, cust.full_name,
       sum(f.amount_reporting * br.weighting_factor) as allocated_deposits_usd
from {{ ref('fct_transactions') }} f
join {{ ref('bridge_account_customer') }} br on br.account_id = f.account_id
join {{ ref('dim_customer') }} cust on cust.customer_key = br.current_customer_key
where f.transaction_type = 'DEPOSIT' and f.status = 'POSTED'
group by 1, 2
order by 3 desc
limit 20;

-- 6. Loan pipeline: median days to decision by product and month applied
select p.product_name, d.year_month,
       count(*)                                                     as applications,
       median(l.days_to_decision)                                   as median_days_to_decision,
       sum(iff(l.is_approved, 1, 0)) / count(*)                     as approval_rate
from {{ ref('fct_loan_applications') }} l
join {{ ref('dim_product') }} p on p.product_key = l.product_key
join {{ ref('dim_date') }}    d on d.date_key = l.applied_date_key
group by 1, 2
order by 2, 1;
