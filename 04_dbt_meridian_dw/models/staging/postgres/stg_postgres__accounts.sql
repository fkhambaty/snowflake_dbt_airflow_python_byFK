with source as (
    select record, _extracted_at from {{ source('postgres_core', 'accounts') }}
),

parsed as (
    select
        record:account_id::number               as account_id,
        record:account_number::string           as account_number,
        record:product_id::number               as product_id,
        record:branch_id::number                as branch_id,
        record:currency_code::varchar(3)        as currency_code,
        record:status::string                   as account_status,
        record:opened_date::date                as opened_date,
        record:closed_date::date                as closed_date,
        record:current_balance::number(18,2)    as current_balance,
        record:credit_limit::number(18,2)       as credit_limit,
        record:interest_rate::number(6,4)       as interest_rate,
        record:created_at::timestamp_ntz        as created_at,
        record:updated_at::timestamp_ntz        as updated_at,
        _extracted_at
    from source
),

latest as (
    select * from parsed
    qualify row_number() over (partition by account_id order by updated_at desc, _extracted_at desc) = 1
)

select *
from latest
where {{ not_deleted('accounts', 'account_id') }}
