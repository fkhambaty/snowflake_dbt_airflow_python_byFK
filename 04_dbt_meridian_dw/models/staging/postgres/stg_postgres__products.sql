with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'products') }}
),

parsed as (
    select
        record:product_id::number               as product_id,
        record:product_code::string             as product_code,
        record:product_name::string             as product_name,
        record:product_category::string         as product_category,
        record:product_type::string             as product_type,
        record:base_interest_rate::number(6,4)  as base_interest_rate,
        record:is_active::boolean               as is_active,
        record:updated_at::timestamp_ntz        as updated_at,
        _extracted_at
    from source
)

select * from parsed
qualify row_number() over (partition by product_id order by updated_at desc, _extracted_at desc) = 1
