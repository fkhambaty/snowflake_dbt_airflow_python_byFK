with source as (
    select record, _extracted_at from {{ source('postgres_core', 'branches') }}
),

parsed as (
    select
        record:branch_id::number            as branch_id,
        record:branch_code::string          as branch_code,
        record:branch_name::string          as branch_name,
        record:country_code::varchar(2)     as country_code,
        record:city::string                 as city,
        record:state_region::string         as state_region,
        record:branch_type::string          as branch_type,
        record:opened_date::date            as opened_date,
        record:status::string               as branch_status,
        record:created_at::timestamp_ntz    as created_at,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
)

select * from parsed
qualify row_number() over (partition by branch_id order by updated_at desc, _extracted_at desc) = 1
