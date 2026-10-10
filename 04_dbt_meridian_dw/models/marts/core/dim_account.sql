{{ config(materialized='table', tags=['daily', 'scd2'],
    grants={'select': ['MERIDIAN_ANALYST', 'MERIDIAN_ML', 'MERIDIAN_APP', 'MERIDIAN_CEO', 'MERIDIAN_BRANCH_MANAGER', 'MERIDIAN_STAFF']},
    meta={'governance': {'row_access': {'policy': 'RAP_BRANCH_INTERNAL', 'column': 'branch_id'}}}) }}

/*
    dim_account - SCD2 on status/branch/product/limits (from snap_accounts, 'check' strategy).
    Product attributes are denormalised in (Type 1) so analysts rarely need dim_product for
    simple slicing; dim_product still exists as a conformed dimension for the bus matrix.
*/

with snap as (
    select * from {{ ref('snap_accounts') }}
),

versions as (
    select s.*, row_number() over (partition by account_id order by dbt_valid_from) as version_number
    from snap s
),

products as (
    select product_id, product_code, product_name, product_category, product_type
    from {{ ref('stg_postgres__products') }}
),

branches as (
    select branch_id, branch_code, country_code as branch_country_code
    from {{ ref('stg_postgres__branches') }}
),

final as (
    select
        {{ dbt_utils.generate_surrogate_key(['v.account_id', 'v.dbt_valid_from']) }} as account_key,
        v.account_id,
        v.account_number,
        v.product_id,
        p.product_code,
        p.product_name,
        p.product_category,
        p.product_type,
        v.branch_id,
        b.branch_code,
        b.branch_country_code,
        v.currency_code,
        v.account_status,
        v.opened_date,
        v.closed_date,
        v.credit_limit,
        v.interest_rate,
        datediff('month', v.opened_date, coalesce(v.closed_date, current_date())) as account_age_months,
        iff(v.version_number = 1, '1900-01-01'::timestamp_ntz, v.dbt_valid_from) as valid_from,
        coalesce(v.dbt_valid_to, '9999-12-31'::timestamp_ntz)   as valid_to,
        v.dbt_valid_to is null                                   as is_current,
        v.version_number
    from versions v
    left join products p on p.product_id = v.product_id
    left join branches b on b.branch_id = v.branch_id
)

select * from final

union all

select '-1', -1, 'UNKNOWN', -1, 'UNKNOWN', 'Unknown product', 'UNKNOWN', 'UNKNOWN', -1, 'UNKNOWN', 'XX',
       'XXX', 'UNKNOWN', '1900-01-01'::date, null, null, null, null,
       '1900-01-01'::timestamp_ntz, '9999-12-31'::timestamp_ntz, true, 1
