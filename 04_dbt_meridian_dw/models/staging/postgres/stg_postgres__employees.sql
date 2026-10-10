with source as (
    select record, _extracted_at from {{ source('postgres_core', 'employees') }}
),

parsed as (
    select
        record:employee_id::number          as employee_id,
        record:employee_code::string        as employee_code,
        record:branch_id::number            as branch_id,
        record:full_name::string            as full_name,
        record:job_title::string            as job_title,
        record:hire_date::date              as hire_date,
        record:is_active::boolean           as is_active,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
)

select * from parsed
qualify row_number() over (partition by employee_id order by updated_at desc, _extracted_at desc) = 1
