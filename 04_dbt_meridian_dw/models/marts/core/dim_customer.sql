{{ config(materialized='table', tags=['daily', 'scd2'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}, 'pii': {'email': 'contact', 'phone': 'contact', 'date_of_birth': 'contact_date'}}}) }}

/*
    dim_customer - SLOWLY CHANGING DIMENSION TYPE 2
    Grain: one row per customer per version of the tracked attributes.

    Built from the dbt snapshot. Two details separate a textbook SCD2 from a working one:
      1. BACKDATING: the first known version is treated as valid from the beginning of time.
         Otherwise a transaction from before the first snapshot run finds no matching version
         and falls to the unknown member.
      2. OPEN-ENDED valid_to = 9999-12-31 (not NULL) so range predicates stay simple and SARGable.
    Plus the unknown member (-1) for facts whose account has no primary holder.
*/

with snap as (
    select * from {{ ref('snap_customers') }}
),

versions as (
    select
        s.*,
        row_number() over (partition by customer_id order by dbt_valid_from) as version_number
    from snap s
),

branches as (
    select branch_id, branch_code, branch_name, country_code as branch_country_code
    from {{ ref('stg_postgres__branches') }}
),

countries as (
    select country_code, country_name, region from {{ ref('stg_postgres__countries') }}
),

final as (
    select
        {{ dbt_utils.generate_surrogate_key(['v.customer_id', 'v.dbt_valid_from']) }} as customer_key,
        v.customer_id,
        v.customer_number,
        v.first_name,
        v.last_name,
        v.full_name,
        v.date_of_birth,
        v.gender,
        v.email,
        v.phone,
        v.kyc_status,
        v.segment,
        v.risk_rating,
        v.home_branch_id,
        b.branch_code                                            as home_branch_code,
        b.branch_name                                            as home_branch_name,
        v.country_code,
        c.country_name,
        c.region,
        v.city,
        v.onboarded_at,
        datediff('year', v.date_of_birth, current_date())        as age_years,
        case
            when datediff('year', v.date_of_birth, current_date()) < 25 then '18-24'
            when datediff('year', v.date_of_birth, current_date()) < 35 then '25-34'
            when datediff('year', v.date_of_birth, current_date()) < 50 then '35-49'
            when datediff('year', v.date_of_birth, current_date()) < 65 then '50-64'
            else '65+'
        end                                                      as age_band,
        datediff('month', v.onboarded_at, current_date())        as tenure_months,
        iff(v.version_number = 1, '1900-01-01'::timestamp_ntz, v.dbt_valid_from) as valid_from,
        coalesce(v.dbt_valid_to, '9999-12-31'::timestamp_ntz)   as valid_to,
        v.dbt_valid_to is null                                   as is_current,
        v.version_number
    from versions v
    left join branches  b on b.branch_id = v.home_branch_id
    left join countries c on c.country_code = v.country_code
)

select * from final

union all

select
    '-1', -1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown customer', '1900-01-01'::date, null, null, null,
    'UNKNOWN', 'UNKNOWN', 'UNKNOWN', -1, 'UNKNOWN', 'Unknown branch', 'XX', 'Unknown', 'UNKNOWN', null,
    '1900-01-01'::timestamp_ntz, null, 'UNKNOWN', null,
    '1900-01-01'::timestamp_ntz, '9999-12-31'::timestamp_ntz, true, 1
