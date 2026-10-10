{{ config(materialized='table', tags=['daily']) }}

/*
    ent_customer_branch — entitlement lookup read by the row access policies.
    One row per current customer and their home branch.

    The policy cannot read dim_customer to find a branch: dim_customer is itself
    protected by that policy, and a policy may not query its own table. This table
    has no policy and no consumer grant. The policy reads it with the policy
    owner's privileges, so no persona ever needs SELECT on it.
*/

select
    customer_id,
    home_branch_id as branch_id
from {{ ref('dim_customer') }}
where is_current
  and customer_id <> -1
  and home_branch_id is not null
