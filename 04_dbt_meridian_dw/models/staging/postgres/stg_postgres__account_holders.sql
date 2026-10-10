with source as (
    select record, _extracted_at from {{ source('postgres_core', 'account_holders') }}
),

parsed as (
    select
        record:account_id::number           as account_id,
        record:customer_id::number          as customer_id,
        record:holder_role::string          as holder_role,
        record:added_at::timestamp_ntz      as added_at,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
),

latest as (
    select * from parsed
    qualify row_number() over (partition by account_id, customer_id order by updated_at desc, _extracted_at desc) = 1
)

-- composite key is logged by the trigger as 'account_id:customer_id'
select *
from latest
where {{ not_deleted('account_holders', "account_id || ':' || customer_id") }}
