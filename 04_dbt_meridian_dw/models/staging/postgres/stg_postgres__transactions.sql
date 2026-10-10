-- depends_on: {{ ref('stg_postgres__deleted_records') }}
{{
    config(
        materialized='incremental',
        unique_key='transaction_id',
        incremental_strategy='merge',
        cluster_by=['transaction_date'],
        post_hook="{{ apply_hard_deletes('transactions', 'transaction_id') }}",
        tags=['hot_path']
    )
}}

/*
    The ONLY incremental staging model. Raw transactions is append-only and grows by millions
    of rows per day; re-parsing all of it every 5 minutes as a view would be wasteful.

    Incremental logic
      * new rows  = raw rows whose _extracted_at is newer than anything we have already parsed
      * MERGE on transaction_id so a status change (PENDING -> POSTED) updates in place
      * within a batch several versions of one id can exist -> QUALIFY keeps the newest
      * hard deletes are applied by the post-hook (a MERGE cannot delete what it does not see)
*/

with source as (

    select record, _extracted_at, _batch_id
    from {{ source('postgres_core', 'transactions') }}
    where 1 = 1
    {% if is_incremental() %}
      -- Re-read a bounded overlap. If a run races a COPY or fails between MERGE and
      -- commit, the next run sees those versions again; unique_key makes that harmless.
      and _extracted_at > (
          select dateadd(
              'hour',
              -{{ var('incremental_lookback_hours') }},
              coalesce(max(_extracted_at), '1900-01-01'::timestamp_ntz)
          )
          from {{ this }}
      )
    {% endif %}
    {{ limit_in_dev('record:transaction_ts::timestamp_ntz') }}

),

parsed as (

    select
        record:transaction_id::number           as transaction_id,
        record:account_id::number               as account_id,
        record:transaction_ts::timestamp_ntz    as transaction_ts,
        to_date(record:transaction_ts::timestamp_ntz) as transaction_date,
        record:transaction_type::string         as transaction_type,
        record:amount::number(18,2)             as amount,
        record:currency_code::varchar(3)        as currency_code,
        record:channel_id::number               as channel_id,
        record:branch_id::number                as branch_id,
        record:employee_id::number              as employee_id,
        record:counterparty_account::string     as counterparty_account,
        record:merchant_category::string        as merchant_category,
        record:status::string                   as status,
        record:reference_no::string             as reference_no,
        record:description::string              as description,
        record:created_at::timestamp_ntz        as created_at,
        record:updated_at::timestamp_ntz        as updated_at,
        _extracted_at,
        _batch_id
    from source

)

select * from parsed
qualify row_number() over (partition by transaction_id order by updated_at desc, _extracted_at desc) = 1
