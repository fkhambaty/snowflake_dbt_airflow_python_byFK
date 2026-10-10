{{
    config(
        materialized='incremental',
        incremental_strategy='delete+insert',
        unique_key='transaction_date',
        cluster_by=['transaction_date'],
        tags=['microbatch'],
        grants={'select': ['MERIDIAN_ANALYST', 'MERIDIAN_ML', 'MERIDIAN_APP', 'MERIDIAN_CEO', 'MERIDIAN_BRANCH_MANAGER', 'MERIDIAN_STAFF']},
        meta={'governance': {'row_access': {'policy': 'RAP_BRANCH_INTERNAL', 'column': 'branch_id'}}}
    )
}}

/*
    agg_branch_daily_performance - AGGREGATE FACT for dashboards.
    Grain: branch x date x currency.

    Incremental strategy = delete+insert on the partition column: every 5 minutes we recompute
    the last 2 days (late status changes!) and swap those partitions. Cheaper than MERGE for
    aggregates, and shows students a second strategy next to fct_transactions' MERGE.
    branch_id is repeated next to branch_key so the branch row-access policy has a
    column to attach to. The surrogate key is not a business id.
*/

with facts as (
    select *
    from {{ ref('fct_transactions') }}
    where status = 'POSTED'
    {% if is_incremental() %}
      and transaction_date >= dateadd('day', -2, (select max(transaction_date) from {{ this }}))
    {% endif %}
),

channels as (
    select channel_key, is_digital from {{ ref('dim_channel') }}
),

agg as (
    select
        f.transaction_date,
        {{ date_key('f.transaction_date') }}                            as date_key,
        f.branch_key,
        f.branch_id,
        f.currency_key,
        f.currency_code,
        count(*)                                                        as transaction_count,
        count(distinct f.account_id)                                    as active_accounts,
        count(distinct f.customer_id)                                   as active_customers,
        sum(iff(f.is_credit, f.amount_local, 0))                        as credits_local,
        sum(iff(f.is_credit, 0, f.amount_local))                        as debits_local,
        sum(f.signed_amount_local)                                      as net_flow_local,
        sum(iff(f.is_credit, f.amount_reporting, 0))                    as credits_reporting,
        sum(iff(f.is_credit, 0, f.amount_reporting))                    as debits_reporting,
        sum(f.signed_amount_reporting)                                  as net_flow_reporting,
        sum(iff(f.transaction_type = 'FEE', f.amount_reporting, 0))     as fee_income_reporting,
        sum(iff(c.is_digital, 1, 0))                                    as digital_transaction_count,
        round(sum(iff(c.is_digital, 1, 0)) / nullif(count(*), 0), 4)    as digital_share,
        avg(f.amount_reporting)                                         as avg_ticket_reporting,
        max(f.transaction_ts)                                           as last_transaction_ts
    from facts f
    left join channels c on c.channel_key = f.channel_key
    group by 1, 2, 3, 4, 5, 6
)

select
    {{ dbt_utils.generate_surrogate_key(['transaction_date', 'branch_key', 'currency_key']) }} as branch_day_key,
    *
from agg
