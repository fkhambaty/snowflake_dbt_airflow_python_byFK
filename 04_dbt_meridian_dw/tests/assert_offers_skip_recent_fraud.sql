-- A customer with a rule-suspect authorization in the last 30 days is not a marketing contact.
select o.customer_id
from {{ ref('fct_next_best_offer') }} o
where o.customer_id in (
    select customer_id
    from {{ ref('fct_card_authorizations') }}
    where is_rule_suspect
      and auth_ts >= dateadd('day', -30, current_timestamp())
)
