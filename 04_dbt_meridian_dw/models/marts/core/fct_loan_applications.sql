{{ config(materialized='table', tags=['daily'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}}) }}

/*
    fct_loan_applications - ACCUMULATING SNAPSHOT FACT
    Grain: one row per loan application, UPDATED IN PLACE as it moves through the pipeline.
    Characteristic shape: many date keys (one per milestone) + lag measures between them.
    Because rows mutate, this fact is rebuilt daily (small table) - with a bigger volume you
    would MERGE on application_id.
*/

with apps as (
    select * from {{ ref('stg_postgres__loan_applications') }}
),

fx as (
    select date_day, currency_code, rate_to_reporting from {{ ref('int_fx_rates_daily_filled') }}
),

cust as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }} where customer_id <> -1),
br   as (select branch_key, branch_id from {{ ref('dim_branch') }}),
prod as (select product_key, product_id from {{ ref('dim_product') }}),
emp  as (select employee_key, employee_id from {{ ref('dim_employee') }}),
cur  as (select currency_key, currency_code from {{ ref('dim_currency') }})

select
    a.application_id,

    -- milestone date keys (-1 = has not happened yet)
    {{ date_key('a.applied_at') }}                                           as applied_date_key,
    coalesce({{ date_key('a.reviewed_at') }}, -1)                            as reviewed_date_key,
    coalesce({{ date_key('a.approved_at') }}, -1)                            as approved_date_key,
    coalesce({{ date_key('a.rejected_at') }}, -1)                            as rejected_date_key,
    coalesce({{ date_key('a.disbursed_at') }}, -1)                           as disbursed_date_key,
    coalesce({{ date_key('a.closed_at') }}, -1)                              as closed_date_key,

    -- dimensions
    coalesce(c.customer_key, '-1')                                           as customer_key,
    coalesce(b.branch_key, '-1')                                             as branch_key,
    coalesce(p.product_key, '-1')                                            as product_key,
    coalesce(e.employee_key, '-1')                                           as loan_officer_key,
    coalesce(cu.currency_key, '-1')                                          as currency_key,
    a.customer_id,
    a.branch_id,
    a.currency_code,
    a.application_status                                                     as current_status,

    -- measures (converted at the APPLICATION-date rate)
    a.amount_requested                                                       as amount_requested_local,
    round(a.amount_requested * fx.rate_to_reporting, 2)                      as amount_requested_reporting,
    a.amount_approved                                                        as amount_approved_local,
    round(a.amount_approved * fx.rate_to_reporting, 2)                       as amount_approved_reporting,
    fx.rate_to_reporting                                                     as fx_rate_to_reporting,

    -- lag measures: the whole point of an accumulating snapshot
    datediff('day', a.applied_at, a.reviewed_at)                             as days_to_review,
    datediff('day', a.applied_at, coalesce(a.approved_at, a.rejected_at))    as days_to_decision,
    datediff('day', a.approved_at, a.disbursed_at)                           as days_approval_to_disbursal,
    datediff('day', a.applied_at, a.disbursed_at)                            as days_to_disbursal,
    datediff('day', a.applied_at, coalesce(a.closed_at, a.disbursed_at, a.rejected_at, a.approved_at, a.reviewed_at, current_timestamp())) as days_in_pipeline,

    -- flags for easy counting
    a.approved_at is not null                                                as is_approved,
    a.rejected_at is not null                                                as is_rejected,
    a.disbursed_at is not null                                               as is_disbursed,
    a.application_status in ('APPLIED', 'UNDER_REVIEW', 'APPROVED')          as is_open,

    a.applied_at, a.reviewed_at, a.approved_at, a.rejected_at, a.disbursed_at, a.closed_at,
    a.updated_at                                                             as source_updated_at
from apps a
left join fx   on fx.date_day = to_date(a.applied_at) and fx.currency_code = a.currency_code
left join cust c  on c.customer_id = a.customer_id and {{ scd2_match('a.applied_at', 'c') }}
left join br   b  on b.branch_id = a.branch_id
left join prod p  on p.product_id = a.product_id
left join emp  e  on e.employee_id = a.loan_officer_id
left join cur  cu on cu.currency_code = a.currency_code
