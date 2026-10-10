with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'currencies') }}
),

parsed as (
    select
        record:currency_code::varchar(3)    as currency_code,
        record:currency_name::string        as currency_name,
        record:symbol::string               as currency_symbol,
        record:minor_units::number          as minor_units,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
)

-- raw is append-only: keep the newest version of each business key
select * from parsed
qualify row_number() over (partition by currency_code order by updated_at desc, _extracted_at desc) = 1
