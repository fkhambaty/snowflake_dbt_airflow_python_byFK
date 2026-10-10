with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'countries') }}
),

parsed as (
    select
        record:country_code::varchar(2)     as country_code,
        record:country_name::string         as country_name,
        record:currency_code::varchar(3)    as local_currency_code,
        record:region::string               as region,
        record:timezone::string             as timezone,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
)

select * from parsed
qualify row_number() over (partition by country_code order by updated_at desc, _extracted_at desc) = 1
