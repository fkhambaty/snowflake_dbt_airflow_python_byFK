-- Singular test: SCD2 versions of the same customer must not overlap and must not leave gaps.
-- Uses LAG to compare each version's valid_from with the previous version's valid_to.
with ordered as (
    select
        customer_id,
        valid_from,
        valid_to,
        lag(valid_to) over (partition by customer_id order by valid_from) as prev_valid_to
    from {{ ref('dim_customer') }}
    where customer_id <> -1
)
select *
from ordered
where prev_valid_to is not null
  and prev_valid_to <> valid_from
