with source as (
    select record, _extracted_at from {{ source('postgres_core', 'credit_cards') }}
),
parsed as (
    select
        record:card_id::number                 as card_id,
        record:card_last4::string              as card_last4,
        record:customer_id::number             as customer_id,
        record:product_id::number              as product_id,
        record:branch_id::number               as branch_id,
        record:currency_code::varchar(3)       as currency_code,
        record:credit_limit::number(18,2)      as credit_limit,
        record:current_outstanding::number(18,2) as current_outstanding,
        record:status::string                  as status,
        record:opened_date::date               as opened_date,
        record:expiry_date::date               as expiry_date,
        record:application_id::number          as application_id,
        record:updated_at::timestamp_ntz       as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by card_id order by updated_at desc, _extracted_at desc) = 1
