with source as (
    select record, _extracted_at
    from {{ source('postgres_core', 'card_authorizations') }}
),
parsed as (
    select
        record:authorization_id::number   as authorization_id,
        record:card_id::number            as card_id,
        record:customer_id::number        as customer_id,
        record:merchant_id::number        as merchant_id,
        record:auth_ts::timestamp_ntz     as auth_ts,
        record:amount::number(18,2)       as amount,
        record:currency_code::varchar(3)  as currency_code,
        record:entry_mode::string         as entry_mode,
        record:card_present::boolean      as card_present,
        record:merchant_country::varchar(2) as merchant_country,
        record:response::string           as response,
        record:decline_reason::string     as decline_reason,
        record:fraud_label::boolean       as fraud_label,
        record:fraud_pattern::string      as fraud_pattern,
        record:updated_at::timestamp_ntz  as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by authorization_id order by updated_at desc, _extracted_at desc) = 1
