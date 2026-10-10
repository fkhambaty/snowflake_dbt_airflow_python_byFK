with source as (
    select record, _extracted_at from {{ source('postgres_core', 'customer_features') }}
),
parsed as (
    select
        record:customer_id::number                  as customer_id,
        record:segment::string                      as segment,
        record:risk_rating::string                  as risk_rating,
        record:age_years::number                    as age_years,
        record:tenure_months::number                as tenure_months,
        record:estimated_annual_income::number(18,2) as estimated_annual_income,
        record:avg_monthly_balance::number(18,2)    as avg_monthly_balance,
        record:salary_credits_3m::number(18,2)      as salary_credits_3m,
        record:as_of_date::date                     as as_of_date,
        record:updated_at::timestamp_ntz            as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by customer_id order by updated_at desc, _extracted_at desc) = 1
