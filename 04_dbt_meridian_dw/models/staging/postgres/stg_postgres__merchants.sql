with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'merchants') }}
),
parsed as (
    select
        record:merchant_id::number        as merchant_id,
        record:merchant_code::string      as merchant_code,
        record:merchant_name::string      as merchant_name,
        record:category_group::string     as category_group,
        record:marketplace::string        as marketplace,
        record:country_code::varchar(2)   as country_code,
        record:is_online::boolean         as is_online,
        record:updated_at::timestamp_ntz  as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by merchant_id order by updated_at desc, _extracted_at desc) = 1
