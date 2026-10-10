{{ config(materialized='table', tags=['daily']) }}

select
    {{ dbt_utils.generate_surrogate_key(['sale_event_id']) }} as sale_event_key,
    sale_event_id,
    marketplace,
    event_name,
    country_code,
    starts_on,
    ends_on,
    datediff('day', starts_on, ends_on) + 1 as duration_days
from {{ ref('stg_postgres__sale_events') }}

union all

select '-1', -1, null, 'Not a sale window', 'XX', null, null, null
