with source as (
    select record, _extracted_at from {{ source('postgres_ref', 'fx_rates') }}
),

parsed as (
    select
        record:fx_rate_id::number           as fx_rate_id,
        record:rate_date::date              as rate_date,
        record:from_currency::varchar(3)    as from_currency,
        record:to_currency::varchar(3)      as to_currency,
        record:rate::number(18,8)           as rate,
        record:source::string               as rate_source,
        record:updated_at::timestamp_ntz    as updated_at,
        _extracted_at
    from source
)

-- Treasury may restate a close (sim_fx_tick does it on purpose). Latest version wins.
select * from parsed
qualify row_number() over (partition by fx_rate_id order by updated_at desc, _extracted_at desc) = 1
