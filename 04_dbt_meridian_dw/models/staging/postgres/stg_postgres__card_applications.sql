with source as (
    select record, _extracted_at from {{ source('postgres_core', 'card_applications') }}
),
parsed as (
    select
        record:application_id::number                 as application_id,
        record:customer_id::number                    as customer_id,
        record:product_id::number                     as product_id,
        record:branch_id::number                      as branch_id,
        record:channel_code::string                   as channel_code,
        record:applied_at::timestamp_ntz              as applied_at,
        record:decided_at::timestamp_ntz              as decided_at,
        record:decision::string                       as decision,
        record:decision_reason::string                as decision_reason,
        record:limit_offered::number(18,2)            as limit_offered,
        record:currency_code::varchar(3)              as currency_code,
        record:segment_at_apply::string               as segment_at_apply,
        record:risk_rating_at_apply::string           as risk_rating_at_apply,
        record:age_years_at_apply::number             as age_years_at_apply,
        record:tenure_months_at_apply::number         as tenure_months_at_apply,
        record:income_at_apply::number(18,2)          as income_at_apply,
        record:balance_at_apply::number(18,2)         as balance_at_apply,
        record:salary_credits_3m_at_apply::number(18,2) as salary_credits_3m_at_apply,
        record:updated_at::timestamp_ntz              as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by application_id order by updated_at desc, _extracted_at desc) = 1
