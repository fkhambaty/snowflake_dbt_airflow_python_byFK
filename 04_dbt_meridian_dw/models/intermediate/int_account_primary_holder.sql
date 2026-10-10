-- One row per account: who is the PRIMARY holder?
-- Used to stamp customer_key on each transaction.
-- Joint holders are handled by bridge_account_customer, not here.
select
    account_id,
    customer_id as primary_customer_id,
    added_at
from {{ ref('stg_postgres__account_holders') }}
where holder_role = 'PRIMARY'
qualify
    row_number()
        over (partition by account_id order by added_at, customer_id)
    = 1
