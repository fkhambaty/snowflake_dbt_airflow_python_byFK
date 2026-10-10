-- Delete log from Postgres trigger cdc.log_delete(). Other staging models anti-join to this.
with source as (
    select record, _extracted_at
    from {{ source('postgres_cdc', 'deleted_records') }}
)

select
    record:deleted_record_id::number        as deleted_record_id,
    record:schema_name::string              as schema_name,
    record:table_name::string               as table_name,
    record:pk_value::string                 as pk_value,
    record:deleted_at::timestamp_ntz        as deleted_at,
    _extracted_at
from source
qualify row_number() over (partition by deleted_record_id order by _extracted_at desc) = 1
