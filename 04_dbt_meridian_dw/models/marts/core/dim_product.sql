{{ config(materialized='table', tags=['daily']) }}

-- SCD Type 1. Small, conformed, shared by fct_transactions (via account) and fct_loan_applications.
select
    {{ dbt_utils.generate_surrogate_key(['product_id']) }} as product_key,
    product_id,
    product_code,
    product_name,
    product_category,
    product_type,
    base_interest_rate,
    is_active
from {{ ref('stg_postgres__products') }}

union all

select '-1', -1, 'UNKNOWN', 'Unknown product', 'UNKNOWN', 'UNKNOWN', null, false
