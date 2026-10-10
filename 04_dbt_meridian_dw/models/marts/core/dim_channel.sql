{{ config(materialized='table', tags=['daily']) }}

select
    {{ dbt_utils.generate_surrogate_key(['channel_id']) }} as channel_key,
    channel_id,
    channel_code,
    channel_name,
    is_digital,
    iff(is_digital, 'DIGITAL', 'PHYSICAL') as channel_group
from {{ ref('stg_postgres__channels') }}

union all

select '-1', -1, 'UNKNOWN', 'Unknown channel', false, 'UNKNOWN'
