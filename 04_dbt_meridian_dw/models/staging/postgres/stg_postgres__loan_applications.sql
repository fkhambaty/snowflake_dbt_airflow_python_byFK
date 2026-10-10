with source as (
    select record, _extracted_at from {{ source('postgres_core', 'loan_applications') }}
),

parsed as (
    select
        record:application_id::number           as application_id,
        record:customer_id::number              as customer_id,
        record:branch_id::number                as branch_id,
        record:product_id::number               as product_id,
        record:loan_officer_id::number          as loan_officer_id,
        record:amount_requested::number(18,2)   as amount_requested,
        record:amount_approved::number(18,2)    as amount_approved,
        record:currency_code::varchar(3)        as currency_code,
        record:status::string                   as application_status,
        record:applied_at::timestamp_ntz        as applied_at,
        record:reviewed_at::timestamp_ntz       as reviewed_at,
        record:approved_at::timestamp_ntz       as approved_at,
        record:rejected_at::timestamp_ntz       as rejected_at,
        record:disbursed_at::timestamp_ntz      as disbursed_at,
        record:closed_at::timestamp_ntz         as closed_at,
        record:updated_at::timestamp_ntz        as updated_at,
        _extracted_at
    from source
)

select * from parsed
qualify row_number() over (partition by application_id order by updated_at desc, _extracted_at desc) = 1
