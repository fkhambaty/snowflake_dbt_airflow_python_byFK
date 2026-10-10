{{ config(materialized='table', tags=['daily']) }}

/*
    dim_transaction_type - a JUNK DIMENSION.
    Low-cardinality flags/codes (type, direction, category, status) are combined into one
    small dimension instead of 4 separate ones or 4 free-text columns on the fact.
    Grain: one row per (transaction_type x status) = 10 x 3 = 30 rows.
*/

with types as (
    select * from {{ ref('transaction_type_mapping') }}
),

statuses as (
    select column1 as status, column2 as status_description, column3 as counts_towards_balance
    from values
        ('POSTED',   'Settled and reflected in balance', true),
        ('PENDING',  'Authorised, not yet settled',      false),
        ('REVERSED', 'Reversed / charged back',          false)
)

select
    {{ dbt_utils.generate_surrogate_key(['t.transaction_type', 's.status']) }} as transaction_type_key,
    t.transaction_type,
    t.direction,
    t.direction = 'CREDIT'          as is_credit,
    t.category,
    t.is_fee,
    t.is_customer_initiated,
    t.description                   as type_description,
    s.status,
    s.status_description,
    s.counts_towards_balance
from types t
cross join statuses s

union all

select '-1', 'UNKNOWN', 'UNKNOWN', false, 'UNKNOWN', false, false, 'Unknown type', 'UNKNOWN', 'Unknown status', false
