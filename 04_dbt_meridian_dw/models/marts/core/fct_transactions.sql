-- depends_on: {{ ref('stg_postgres__deleted_records') }}
{{
    config(
        materialized='incremental',
        unique_key='transaction_id',
        incremental_strategy='merge',
        merge_exclude_columns=['inserted_at'],
        cluster_by=['transaction_date'],
        post_hook="{{ apply_hard_deletes('transactions', 'transaction_id') }}",
        tags=['microbatch', 'hot_path'],
        meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}}
    )
}}

/*
    fct_transactions - TRANSACTION FACT (the atomic grain of the bank)
    Grain  : one row per transaction_id (latest known status)
    Keys   : date, account(SCD2 PIT), customer(SCD2 PIT), branch, product, channel, currency,
             transaction_type x status (junk), employee
    Measures: amount_local, amount_reporting, signed variants, fx_rate_to_reporting
    Degenerate dims: transaction_id, reference_no, counterparty_account, merchant_category

    SCD2 point-in-time joins use valid_from <= ts < valid_to. Without that predicate every
    customer version would match -> fan-out (06_performance_lab/04).
*/

with txns as (

    select *
    from {{ ref('int_transactions_with_fx') }}
    {% if is_incremental() %}
    where _extracted_at > (
        select dateadd('hour', -{{ var('incremental_lookback_hours') }}, coalesce(max(_extracted_at), '1900-01-01'::timestamp_ntz))
        from {{ this }}
    )
    {% endif %}

),

dim_account   as (select account_key, account_id, product_id, valid_from, valid_to from {{ ref('dim_account') }} where account_id <> -1),
dim_customer  as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }} where customer_id <> -1),
dim_branch    as (select branch_key, branch_id from {{ ref('dim_branch') }}),
dim_product   as (select product_key, product_id from {{ ref('dim_product') }}),
dim_channel   as (select channel_key, channel_id from {{ ref('dim_channel') }}),
dim_currency  as (select currency_key, currency_code from {{ ref('dim_currency') }}),
dim_employee  as (select employee_key, employee_id from {{ ref('dim_employee') }}),
dim_txn_type  as (select transaction_type_key, transaction_type, status from {{ ref('dim_transaction_type') }}),

final as (

    select
        -- degenerate dimension / primary key
        t.transaction_id,

        -- foreign keys (surrogate); every unmatched lookup falls to the unknown member '-1'
        {{ date_key('t.transaction_ts') }}            as date_key,
        coalesce(da.account_key, '-1')                as account_key,
        coalesce(dc.customer_key, '-1')               as customer_key,
        coalesce(db.branch_key, '-1')                 as branch_key,
        coalesce(dp.product_key, '-1')                as product_key,
        coalesce(dch.channel_key, '-1')               as channel_key,
        coalesce(dcur.currency_key, '-1')             as currency_key,
        coalesce(dtt.transaction_type_key, '-1')      as transaction_type_key,
        coalesce(de.employee_key, '-1')               as employee_key,

        -- natural keys kept for reconciliation and cheap filtering
        t.account_id,
        t.primary_customer_id                         as customer_id,
        t.branch_id,
        t.currency_code,
        t.transaction_type,
        t.status,

        -- timestamps
        t.transaction_ts,
        t.transaction_date,

        -- measures
        t.amount_local,
        t.amount_reporting,
        t.signed_amount_local,
        t.signed_amount_reporting,
        t.fx_rate_to_reporting,
        t.fx_is_forward_filled,
        t.is_credit,
        1                                             as transaction_count,

        -- other degenerate attributes
        t.reference_no,
        t.counterparty_account,
        t.merchant_category,

        -- lineage
        t.updated_at                                  as source_updated_at,
        t._extracted_at,
        current_timestamp()::timestamp_ntz           as inserted_at,
        current_timestamp()::timestamp_ntz           as dbt_updated_at
    from txns t
    left join dim_account  da  on da.account_id  = t.account_id          and {{ scd2_match('t.transaction_ts', 'da') }}
    left join dim_customer dc  on dc.customer_id = t.primary_customer_id and {{ scd2_match('t.transaction_ts', 'dc') }}
    left join dim_branch   db  on db.branch_id   = t.branch_id
    left join dim_product  dp  on dp.product_id  = da.product_id
    left join dim_channel  dch on dch.channel_id = t.channel_id
    left join dim_currency dcur on dcur.currency_code = t.currency_code
    left join dim_employee de  on de.employee_id = t.employee_id
    left join dim_txn_type dtt on dtt.transaction_type = t.transaction_type and dtt.status = t.status

)

select * from final
