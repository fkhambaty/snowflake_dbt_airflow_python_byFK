{{ config(materialized='table', tags=['daily'],
    meta={'governance': {'row_access': {'policy': 'RAP_BRANCH_SCOPE', 'column': 'branch_id'}}}) }}

/*
    dim_branch - SCD TYPE 1 (overwrite). A branch rename should update history, so the
    surrogate key is stable per branch_id. Country attributes are denormalised (star, not snowflake).
    History is still preserved in snap_branches if the business ever asks for Type 2.
*/

with branches as (
    select * from {{ ref('stg_postgres__branches') }}
),

countries as (
    select * from {{ ref('stg_postgres__countries') }}
),

final as (
    select
        {{ dbt_utils.generate_surrogate_key(['b.branch_id']) }}  as branch_key,
        b.branch_id,
        b.branch_code,
        b.branch_name,
        b.branch_type,
        b.branch_status,
        b.city,
        b.state_region,
        b.country_code,
        c.country_name,
        c.region,
        c.local_currency_code,
        c.timezone                                                as local_timezone,
        b.opened_date,
        datediff('year', b.opened_date, current_date())           as branch_age_years
    from branches b
    left join countries c on c.country_code = b.country_code
)

select * from final

union all

select '-1', -1, 'UNKNOWN', 'Unknown / digital channel', 'DIGITAL_HUB', 'UNKNOWN', 'Unknown', null,
       'XX', 'Unknown', 'UNKNOWN', 'XXX', 'UTC', '1900-01-01'::date, null
