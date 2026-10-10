{{ config(materialized='table', tags=['daily'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}}) }}

/*
    bridge_account_customer - resolves the MANY-TO-MANY between accounts and customers
    (joint accounts). Kimball pattern: bridge table with a WEIGHTING FACTOR so that
    "deposits per customer" can be allocated without double counting:

        sum(f.amount_reporting * br.weighting_factor)   -- allocated view, totals reconcile
        sum(f.amount_reporting)                          -- impact view, intentionally double counts

    Keys: natural keys (account_id, customer_id) for robustness across SCD2 versions, plus the
    CURRENT surrogate keys for convenience in BI tools.
*/

with holders as (
    select * from {{ ref('stg_postgres__account_holders') }}
),

counts as (
    select account_id, count(*) as holder_count
    from holders
    group by account_id
),

cur_accounts as (
    select account_key, account_id from {{ ref('dim_account') }} where is_current
),

cur_customers as (
    select customer_key, customer_id from {{ ref('dim_customer') }} where is_current
)

select
    {{ dbt_utils.generate_surrogate_key(['h.account_id', 'h.customer_id']) }} as bridge_key,
    h.account_id,
    h.customer_id,
    a.account_key                       as current_account_key,
    c.customer_key                      as current_customer_key,
    h.holder_role,
    h.holder_role = 'PRIMARY'           as is_primary_holder,
    n.holder_count,
    round(1.0 / n.holder_count, 6)      as weighting_factor,
    h.added_at
from holders h
join counts n on n.account_id = h.account_id
left join cur_accounts  a on a.account_id = h.account_id
left join cur_customers c on c.customer_id = h.customer_id
