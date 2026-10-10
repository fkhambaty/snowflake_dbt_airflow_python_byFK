{{ config(materialized='table', tags=['daily']) }}

select
    offer_code,
    offer_name,
    offer_family,
    marketplace,
    cashback_rate,
    description,
    is_active
from {{ ref('stg_postgres__offer_catalog') }}
