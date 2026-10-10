{% snapshot snap_customers %}

{{
    config(
        unique_key='customer_id',
        strategy='timestamp',
        updated_at='updated_at',
        hard_deletes='invalidate'
    )
}}

/*
    dbt snapshot = Type-2 history recorder.
      * strategy='timestamp': a new version is written whenever updated_at moves forward.
        (The Postgres trigger guarantees updated_at is always bumped - see 04_cdc_triggers.sql.)
      * dbt_valid_from = the source updated_at, dbt_valid_to = NULL for the current version.
      * hard_deletes='invalidate': a customer that disappears from staging gets closed off.
    Metadata columns (_extracted_at) are excluded so they do not pollute the history.
*/

select
    customer_id,
    customer_number,
    first_name,
    last_name,
    full_name,
    date_of_birth,
    gender,
    email,
    phone,
    kyc_status,
    segment,
    risk_rating,
    home_branch_id,
    country_code,
    city,
    onboarded_at,
    created_at,
    updated_at
from {{ ref('stg_postgres__customers') }}

{% endsnapshot %}
