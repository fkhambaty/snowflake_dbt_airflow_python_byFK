with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'channels') }}
),

parsed as (
    select
        record:channel_id::number           as channel_id,
        record:channel_code::string         as channel_code,
        record:channel_name::string         as channel_name,
        record:is_digital::boolean          as is_digital,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
)

select * from parsed
qualify row_number() over (partition by channel_id order by updated_at desc, _extracted_at desc) = 1
