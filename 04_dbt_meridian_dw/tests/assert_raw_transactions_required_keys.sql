{{ config(severity='warn') }}

/*
  VARIANT lets a new optional source column land without breaking COPY. It must not make a
  breaking rename invisible. Recent records missing a key that staging requires are returned
  as failures. Warn first: raw remains available while the source and model owners agree on
  whether the change is additive, a rename, or corrupt data.
*/
select
    _batch_id,
    _source_file,
    _extracted_at,
    record
from {{ source('postgres_core', 'transactions') }}
where _extracted_at >= dateadd('day', -1, current_timestamp())
  and (
       record:transaction_id is null
    or record:account_id is null
    or record:transaction_ts is null
    or record:transaction_type is null
    or record:amount is null
    or record:currency_code is null
    or record:status is null
    or record:updated_at is null
  )
