{{ config(materialized='table', tags=['daily'], cluster_by=['snapshot_date'],
    grants={'select': ['MERIDIAN_ANALYST', 'MERIDIAN_ML', 'MERIDIAN_APP', 'MERIDIAN_CEO', 'MERIDIAN_BRANCH_MANAGER', 'MERIDIAN_STAFF']},
    meta={'governance': {'row_access': {'policy': 'RAP_BRANCH_INTERNAL', 'column': 'branch_id'}}}) }}

/*
    fct_monthly_account_balance - PERIODIC SNAPSHOT FACT
    Grain: one row per account per month-end (from the month the account opened until today).
    branch_id is on the row so a branch row-access policy can attach. The customer login is
    not granted this table: a branch total includes other customers' balances.

    Why a snapshot fact at all? "What was the total deposit book on 31 March?" cannot be
    answered quickly from millions of transaction rows. A periodic snapshot pre-computes the
    stock (balance) at regular intervals; the transaction fact holds the flows.

    Currency subtlety (very common interview follow-up):
      * flows (transactions) are converted at the TRANSACTION-DATE rate -> fct_transactions
      * stocks (balances) are converted at the PERIOD-END rate -> here
      Summing converted flows does NOT equal converting the summed balance. Both are "right";
      finance decides which one a report uses. We expose both so the difference is visible.

    Exercise for students: change the grain to daily (account x day). It is ~30x bigger - a
    perfect candidate for the performance lab.
*/

with month_ends as (
    select distinct month_end_date as snapshot_date
    from {{ ref('dim_date') }}
    where month_end_date <= current_date() and date_key <> -1
),

accounts as (
    select account_id, account_key, currency_code, opened_date, product_id, branch_id
    from {{ ref('dim_account') }}
    where is_current and account_id <> -1
),

spine as (
    select a.account_id, a.account_key, a.currency_code, a.product_id, a.branch_id, m.snapshot_date
    from accounts a
    join month_ends m on m.snapshot_date >= last_day(a.opened_date)
),

monthly_flows as (
    select
        account_id,
        last_day(transaction_date)                  as snapshot_date,
        sum(signed_amount_local)                    as net_flow_local,
        sum(signed_amount_reporting)                as net_flow_reporting_at_txn_rate,
        count(*)                                    as transaction_count,
        sum(iff(is_credit, amount_local, 0))        as credits_local,
        sum(iff(is_credit, 0, amount_local))        as debits_local
    from {{ ref('fct_transactions') }}
    where status = 'POSTED'
    group by 1, 2
),

running as (
    select
        s.*,
        coalesce(f.transaction_count, 0)                            as transaction_count,
        coalesce(f.credits_local, 0)                                as credits_local,
        coalesce(f.debits_local, 0)                                 as debits_local,
        coalesce(f.net_flow_local, 0)                               as net_flow_local,
        coalesce(f.net_flow_reporting_at_txn_rate, 0)               as net_flow_reporting_at_txn_rate,
        sum(coalesce(f.net_flow_local, 0)) over (
            partition by s.account_id order by s.snapshot_date
            rows between unbounded preceding and current row
        )                                                           as closing_balance_local,
        sum(coalesce(f.net_flow_reporting_at_txn_rate, 0)) over (
            partition by s.account_id order by s.snapshot_date
            rows between unbounded preceding and current row
        )                                                           as closing_balance_reporting_at_txn_rates
    from spine s
    left join monthly_flows f on f.account_id = s.account_id and f.snapshot_date = s.snapshot_date
),

fx as (
    select date_day, currency_code, rate_to_reporting from {{ ref('fct_fx_rates_daily') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['r.account_id', 'r.snapshot_date']) }} as account_balance_key,
    {{ date_key('r.snapshot_date') }}                                        as snapshot_date_key,
    r.snapshot_date,
    r.account_key,
    coalesce(db.branch_key, '-1')                                            as branch_key,
    coalesce(dp.product_key, '-1')                                           as product_key,
    coalesce(dcur.currency_key, '-1')                                        as currency_key,
    r.account_id,
    r.branch_id,
    r.currency_code,
    r.transaction_count,
    r.credits_local,
    r.debits_local,
    r.net_flow_local,
    r.closing_balance_local,
    round(r.closing_balance_local * fx.rate_to_reporting, 2)                 as closing_balance_reporting_at_period_end_rate,
    r.closing_balance_reporting_at_txn_rates,
    fx.rate_to_reporting                                                     as period_end_fx_rate,
    r.transaction_count = 0                                                  as is_inactive_month
from running r
left join fx on fx.date_day = least(r.snapshot_date, current_date()) and fx.currency_code = r.currency_code
left join {{ ref('dim_branch') }}   db   on db.branch_id = r.branch_id
left join {{ ref('dim_product') }}  dp   on dp.product_id = r.product_id
left join {{ ref('dim_currency') }} dcur on dcur.currency_code = r.currency_code
