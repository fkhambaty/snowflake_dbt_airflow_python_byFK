{{ config(materialized='table', tags=['daily']) }}

select
    {{ dbt_utils.generate_surrogate_key(['merchant_id']) }} as merchant_key,
    merchant_id,
    merchant_code,
    merchant_name,
    category_group,
    marketplace,
    marketplace is not null as is_marketplace,
    country_code,
    is_online
from {{ ref('stg_postgres__merchants') }}

union all

select '-1', -1, 'UNKNOWN', 'Unknown merchant', 'OTHER', null, false, 'XX', false
