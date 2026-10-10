{% snapshot snap_branches %}

{{
    config(
        unique_key='branch_id',
        strategy='timestamp',
        updated_at='updated_at',
        hard_deletes='invalidate'
    )
}}

-- Branch history is kept for audit (renames, status changes), but dim_branch is built as
-- Type 1 (current values only) from staging. Having the snapshot lets you switch dim_branch
-- to Type 2 later without losing any history: a cheap insurance policy.
select
    branch_id,
    branch_code,
    branch_name,
    country_code,
    city,
    state_region,
    branch_type,
    opened_date,
    branch_status,
    created_at,
    updated_at
from {{ ref('stg_postgres__branches') }}

{% endsnapshot %}
