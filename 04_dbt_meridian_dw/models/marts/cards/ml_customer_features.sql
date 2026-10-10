{{ config(
    materialized='table',
    tags=['daily'],
    meta={'governance': {
        'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'},
        'pii': {'estimated_annual_income': 'income', 'avg_monthly_balance': 'income', 'salary_credits_3m': 'income'}
    }}
) }}

/*
    ml_customer_features — one row per current customer, as of today.

    The single definition of the customer features. The training job reads this
    table, and fct_next_best_offer scores from it. A feature computed one way for
    training and another way in production (training/serving skew) is the most
    common reason a model that scored well offline fails live.

    Behaviour comes from the warehouse, not from the source system's own summary:
      avg_monthly_balance  mean of the last three month-end balances, primary accounts, local currency
      salary_credits_3m    posted SALARY_CREDIT in the last 90 days, local currency
    Declared income is what the customer told the bank; the warehouse cannot derive it.
    The source's precomputed value is used only when the warehouse has no history yet,
    and feature_source says which one a row used.

    Label for the propensity model: has_been_approved. It describes the past, the
    features describe today — a known simplification, said out loud in Module 10.
*/

with customers as (
    select customer_id, segment, risk_rating, kyc_status, age_years, tenure_months, country_code, home_branch_id
    from {{ ref('dim_customer_current') }}
),
declared as (
    select customer_id, estimated_annual_income, avg_monthly_balance, salary_credits_3m
    from {{ ref('stg_postgres__customer_features') }}
),
primary_accounts as (
    select account_id, primary_customer_id as customer_id
    from {{ ref('int_account_primary_holder') }}
),
month_end_balance as (
    select
        p.customer_id,
        b.snapshot_date,
        sum(b.closing_balance_local) as balance
    from {{ ref('fct_monthly_account_balance') }} b
    join primary_accounts p on p.account_id = b.account_id
    where b.snapshot_date >= dateadd('month', -3, current_date())
    group by 1, 2
),
balance as (
    select customer_id, avg(balance) as avg_monthly_balance
    from month_end_balance
    group by 1
),
salary as (
    select customer_id, sum(amount_local) as salary_credits_3m
    from {{ ref('fct_transactions') }}
    where transaction_type = 'SALARY_CREDIT'
      and status = 'POSTED'
      and transaction_date >= dateadd('day', -90, current_date())
    group by 1
),
cards as (
    select
        customer_id,
        max(iff(status = 'ACTIVE', 1, 0)) = 1  as has_active_card,
        max(iff(status = 'BLOCKED', 1, 0)) = 1 as has_blocked_card,
        max(iff(credit_limit > 0, current_outstanding / credit_limit, null)) as utilization
    from {{ ref('dim_card') }}
    where card_id <> -1
    group by 1
),
approvals as (
    select customer_id, max(iff(decision = 'APPROVED', 1, 0)) = 1 as has_been_approved
    from {{ ref('fct_card_applications') }}
    group by 1
)

select
    c.customer_id,
    c.home_branch_id,
    c.segment,
    c.risk_rating,
    c.kyc_status,
    c.age_years,
    c.tenure_months,
    c.country_code,
    d.estimated_annual_income,
    coalesce(b.avg_monthly_balance, d.avg_monthly_balance)  as avg_monthly_balance,
    coalesce(s.salary_credits_3m, d.salary_credits_3m)      as salary_credits_3m,
    case
        when b.customer_id is not null and s.customer_id is not null then 'WAREHOUSE'
        when b.customer_id is not null or s.customer_id is not null then 'MIXED'
        else 'SOURCE_FALLBACK'
    end                                                      as feature_source,
    coalesce(k.has_active_card, false)                       as has_active_card,
    coalesce(k.has_blocked_card, false)                      as has_blocked_card,
    k.utilization,
    coalesce(a.has_been_approved, false)                     as has_been_approved,
    current_date()                                           as as_of_date
from customers c
join declared d on d.customer_id = c.customer_id
left join balance b on b.customer_id = c.customer_id
left join salary s on s.customer_id = c.customer_id
left join cards k on k.customer_id = c.customer_id
left join approvals a on a.customer_id = c.customer_id
