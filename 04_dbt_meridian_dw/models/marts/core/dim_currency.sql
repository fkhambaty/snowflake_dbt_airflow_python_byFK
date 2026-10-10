{{ config(materialized='table', tags=['daily']) }}

select
    {{ dbt_utils.generate_surrogate_key(['currency_code']) }} as currency_key,
    currency_code,
    currency_name,
    currency_symbol,
    minor_units,
    currency_code = '{{ var("reporting_currency") }}' as is_reporting_currency
from {{ ref('stg_postgres__currencies') }}

union all

select '-1', 'XXX', 'Unknown currency', '?', 2, false
