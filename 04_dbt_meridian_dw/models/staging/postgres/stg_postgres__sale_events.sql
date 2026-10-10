with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'sale_events') }}
),
parsed as (
    select
        record:sale_event_id::number      as sale_event_id,
        record:marketplace::string        as marketplace,
        record:event_name::string         as event_name,
        record:country_code::varchar(2)   as country_code,
        record:starts_on::date            as starts_on,
        record:ends_on::date              as ends_on,
        record:updated_at::timestamp_ntz  as updated_at,
        _extracted_at
    from source
)
select * from parsed
qualify row_number() over (partition by sale_event_id order by updated_at desc, _extracted_at desc) = 1
