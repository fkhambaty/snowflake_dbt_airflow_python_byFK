with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'offer_catalog') }}
),
parsed as (
    select
        record:offer_code::string         as offer_code,
        record:offer_name::string         as offer_name,
        record:offer_family::string       as offer_family,
        record:marketplace::string        as marketplace,
        record:cashback_rate::number(6,4) as cashback_rate,
        record:description::string        as description,
        record:is_active::boolean         as is_active,
        record:updated_at::timestamp_ntz  as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by offer_code order by updated_at desc, _extracted_at desc) = 1
