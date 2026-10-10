with source as (
    select record, _extracted_at from {{ source('postgres_core', 'customers') }}
),

parsed as (
    select
        record:customer_id::number          as customer_id,
        record:customer_number::string      as customer_number,
        record:first_name::string           as first_name,
        record:last_name::string            as last_name,
        record:first_name::string || ' ' || record:last_name::string as full_name,
        record:date_of_birth::date          as date_of_birth,
        record:gender::varchar(1)           as gender,
        record:email::string                as email,
        record:phone::string                as phone,
        record:kyc_status::string           as kyc_status,
        record:segment::string              as segment,
        record:risk_rating::string          as risk_rating,
        record:home_branch_id::number       as home_branch_id,
        record:country_code::varchar(2)     as country_code,
        record:city::string                 as city,
        record:onboarded_at::timestamp_ntz  as onboarded_at,
        record:created_at::timestamp_ntz    as created_at,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
),

latest as (
    select * from parsed
    qualify row_number() over (partition by customer_id order by updated_at desc, _extracted_at desc) = 1
)

select *
from latest
where {{ not_deleted('customers', 'customer_id') }}
