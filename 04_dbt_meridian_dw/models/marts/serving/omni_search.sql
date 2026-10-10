-- depends_on: {{ ref('stg_postgres__deleted_records') }}
{{
    config(
        materialized='incremental',
        unique_key='search_id',
        incremental_strategy='merge',
        tags=['microbatch', 'hot_path'],
        meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}},
        post_hook=[
            "{{ prune_omni_search_deletes() }}",
            "{{ apply_governance() }}"
        ]
    )
}}

/*
    omni_search — one identifier per row, so a fragment of an id can be found
    wherever that identifier lives (transaction, reference number, account,
    customer, card authorization).

    This is a serving index, not a fact. It is not a row on the bus matrix.
    Grain: one row per (entity_type, entity_id, match_on).

    Why a table and not a view over every mart
      * Search Optimization (the access path for "part of an id") attaches to tables.
      * A view with LIKE '%x%' on five facts scans each of them.
      * The row access policy is on THIS table, so the app, a worksheet and the
        semantic layer all obey the same rule. Names, email and phone are not
        indexed. Identifier search is not people search.

    Freshness
      * Transaction ids, reference numbers and authorization ids merge on the
        5-minute path (only rows extracted since the last run).
      * Account numbers and customer ids change rarely. They merge on the daily
        build, which passes var search_refresh_reference = true.
      * The first build (not incremental) loads every identifier.

    search_text is stored uppercased so the query can be
    CONTAINS(search_text, :fragment) with no function wrapped around the column.
    UPPER(search_text) in the WHERE would make Snowflake ignore Search Optimization.

    Clustering this table on search_text would not help: a contains-predicate
    cannot prune on min/max metadata. The access path is Search Optimization
    ON SUBSTRING(search_text), added once by 03_snowflake/07_omni_search.sql.
    Do not --full-refresh this model casually: that drops the search access path.
*/

with transactions as (

    select
        transaction_id,
        reference_no,
        customer_id,
        branch_id,
        transaction_date,
        amount_reporting,
        currency_code,
        status,
        transaction_type,
        _extracted_at
    from {{ ref('fct_transactions') }}
    where customer_id is not null
      and customer_id <> -1
    {% if is_incremental() %}
      and _extracted_at > (
          select dateadd(
              'hour',
              -{{ var('incremental_lookback_hours') }},
              coalesce(max(source_extracted_at), '1900-01-01'::timestamp_ntz)
          )
          from {{ this }}
          where entity_type = 'TRANSACTION'
      )
    {% endif %}

),

authorizations as (

    select
        authorization_id,
        customer_id,
        auth_date,
        amount_reporting,
        response,
        marketplace,
        _extracted_at
    from {{ ref('fct_card_authorizations') }}
    where customer_id is not null
      and customer_id <> -1
    {% if is_incremental() %}
      and _extracted_at > (
          select dateadd(
              'hour',
              -{{ var('incremental_lookback_hours') }},
              coalesce(max(source_extracted_at), '1900-01-01'::timestamp_ntz)
          )
          from {{ this }}
          where entity_type = 'CARD_AUTHORIZATION'
      )
    {% endif %}

),

txn_ids as (

    select
        'TRANSACTION'                                              as entity_type,
        transaction_id::varchar                                    as entity_id,
        'TRANSACTION_ID'                                           as match_on,
        transaction_id::varchar                                    as search_text,
        customer_id,
        branch_id,
        transaction_date                                           as occurred_on,
        amount_reporting,
        currency_code,
        status || ' ' || transaction_type                         as summary,
        'fct_transactions'                                         as source_model,
        _extracted_at                                              as source_extracted_at
    from transactions

),

txn_refs as (

    select
        'TRANSACTION'                                              as entity_type,
        transaction_id::varchar                                    as entity_id,
        'REFERENCE_NO'                                             as match_on,
        upper(reference_no)                                        as search_text,
        customer_id,
        branch_id,
        transaction_date                                           as occurred_on,
        amount_reporting,
        currency_code,
        status || ' ' || transaction_type                         as summary,
        'fct_transactions'                                         as source_model,
        _extracted_at                                              as source_extracted_at
    from transactions
    where reference_no is not null

),

auth_ids as (

    select
        'CARD_AUTHORIZATION'                                       as entity_type,
        authorization_id::varchar                                  as entity_id,
        'AUTHORIZATION_ID'                                         as match_on,
        authorization_id::varchar                                  as search_text,
        customer_id,
        null::number                                               as branch_id,
        auth_date                                                  as occurred_on,
        amount_reporting,
        null::varchar                                              as currency_code,
        response || coalesce(' ' || marketplace, '')               as summary,
        'fct_card_authorizations'                                  as source_model,
        _extracted_at                                              as source_extracted_at
    from authorizations

),

{% if not is_incremental() or var('search_refresh_reference', false) %}
accounts as (

    select
        a.account_id,
        a.account_number,
        h.primary_customer_id                                      as customer_id,
        a.branch_id,
        a.opened_date,
        a.currency_code,
        a.account_status,
        a.product_name
    from {{ ref('dim_account') }} a
    inner join {{ ref('int_account_primary_holder') }} h
        on h.account_id = a.account_id
    where a.is_current
      and a.account_id <> -1

),

account_numbers as (

    select
        'ACCOUNT'                                                   as entity_type,
        account_id::varchar                                         as entity_id,
        'ACCOUNT_NUMBER'                                            as match_on,
        upper(account_number)                                       as search_text,
        customer_id,
        branch_id,
        opened_date                                                 as occurred_on,
        null::number(18, 2)                                        as amount_reporting,
        currency_code,
        account_status || ' ' || product_name                      as summary,
        'dim_account'                                               as source_model,
        null::timestamp_ntz                                        as source_extracted_at
    from accounts
    where account_number is not null

),

account_ids as (

    select
        'ACCOUNT'                                                   as entity_type,
        account_id::varchar                                         as entity_id,
        'ACCOUNT_ID'                                                as match_on,
        account_id::varchar                                         as search_text,
        customer_id,
        branch_id,
        opened_date                                                 as occurred_on,
        null::number(18, 2)                                        as amount_reporting,
        currency_code,
        account_status || ' ' || product_name                      as summary,
        'dim_account'                                               as source_model,
        null::timestamp_ntz                                        as source_extracted_at
    from accounts

),

customer_ids as (

    select
        'CUSTOMER'                                                  as entity_type,
        customer_id::varchar                                        as entity_id,
        'CUSTOMER_ID'                                               as match_on,
        customer_id::varchar                                        as search_text,
        customer_id,
        home_branch_id                                              as branch_id,
        onboarded_at::date                                          as occurred_on,
        null::number(18, 2)                                        as amount_reporting,
        null::varchar                                               as currency_code,
        'branch ' || coalesce(home_branch_code, 'UNKNOWN')         as summary,
        'dim_customer'                                              as source_model,
        null::timestamp_ntz                                        as source_extracted_at
    from {{ ref('dim_customer') }}
    where is_current
      and customer_id <> -1

),
{% endif %}

stacked as (

    select * from txn_ids
    union all
    select * from txn_refs
    union all
    select * from auth_ids
    {% if not is_incremental() or var('search_refresh_reference', false) %}
    union all
    select * from account_numbers
    union all
    select * from account_ids
    union all
    select * from customer_ids
    {% endif %}

)

select
    {{ dbt_utils.generate_surrogate_key(['entity_type', 'entity_id', 'match_on']) }} as search_id,
    entity_type,
    entity_id,
    match_on,
    upper(search_text) as search_text,
    customer_id,
    branch_id,
    occurred_on,
    amount_reporting,
    currency_code,
    summary,
    source_model,
    source_extracted_at
from stacked
where search_text is not null
  and customer_id is not null
  and customer_id <> -1
