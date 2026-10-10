{{ config(materialized='table', tags=['daily'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}}) }}

select
    {{ dbt_utils.generate_surrogate_key(['card_id']) }} as card_key,
    card_id,
    card_last4,
    customer_id,
    product_id,
    branch_id,
    currency_code,
    credit_limit,
    current_outstanding,
    case when credit_limit = 0 then null else current_outstanding / credit_limit end as utilization,
    status,
    opened_date,
    expiry_date,
    application_id
from {{ ref('stg_postgres__credit_cards') }}

union all

select '-1', -1, '0000', -1, -1, -1, 'XXX', null, null, null, 'UNKNOWN', null, null, null
