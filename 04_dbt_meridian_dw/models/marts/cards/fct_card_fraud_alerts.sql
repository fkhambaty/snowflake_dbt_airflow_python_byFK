{{ config(materialized='view', tags=['daily', 'cards']) }}

-- The queue a fraud analyst opens. Rules only; the synthetic label stays on the fact for grading.
select
    authorization_id,
    auth_ts,
    customer_id,
    card_id,
    amount_local,
    amount_reporting,
    marketplace,
    merchant_country,
    customer_country,
    entry_mode,
    is_velocity,
    is_geo_mismatch,
    is_high_amount,
    is_card_testing,
    response
from {{ ref('fct_card_authorizations') }}
where is_rule_suspect
