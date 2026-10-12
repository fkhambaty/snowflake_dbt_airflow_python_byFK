-- Singular test: referential integrity of the transaction mart.
-- A returned row fails dbt build. store_failures keeps the key and the reason.
--
-- Snowflake PRIMARY KEY and FOREIGN KEY constraints are informational. They do not
-- reject a duplicate business key or an orphan fact. NOT NULL is enforced.
-- This test is the enforced stand-in for those keys. The same rules are re-checked
-- after publish by 03_snowflake/11_mart_integrity_and_quarantine.sql, because a
-- table can be changed outside dbt.
--
-- Unknown member: fct_transactions points a missing lookup at '-1'. That is a
-- conformed choice, not an orphan, when the dimension contains '-1'. A fact key
-- that is neither a real member nor that unknown member fails the test. If facts
-- use '-1' and the dimension has no such row, the unknown-member choice is broken
-- and the test fails too.
-- SCD2 allows many customer versions. The business key of a version is
-- (customer_id, valid_from), not customer_id alone.

with duplicate_transaction as (
    select
        'FCT_TRANSACTIONS' as object_name,
        transaction_id::varchar as business_key,
        'DUPLICATE_BUSINESS_KEY' as violation_type,
        'transaction_id appears ' || count(*) || ' times. A Snowflake PRIMARY KEY would not have stopped this.' as reason
    from {{ ref('fct_transactions') }}
    group by transaction_id
    having count(*) > 1
),

duplicate_branch as (
    select
        'DIM_BRANCH' as object_name,
        branch_id::varchar as business_key,
        'DUPLICATE_BUSINESS_KEY' as violation_type,
        'branch_id appears ' || count(*) || ' times' as reason
    from {{ ref('dim_branch') }}
    group by branch_id
    having count(*) > 1
),

duplicate_customer_version as (
    select
        'DIM_CUSTOMER' as object_name,
        customer_id::varchar || '|' || to_varchar(valid_from, 'YYYY-MM-DD HH24:MI:SS.FF3') as business_key,
        'DUPLICATE_BUSINESS_KEY' as violation_type,
        'customer_id ' || customer_id::varchar || ' has ' || count(*) || ' rows for the same valid_from' as reason
    from {{ ref('dim_customer') }}
    where customer_id <> -1
    group by customer_id, valid_from
    having count(*) > 1
),

orphan_account as (
    select
        'FCT_TRANSACTIONS' as object_name,
        f.transaction_id::varchar as business_key,
        'ORPHAN_FACT' as violation_type,
        'account_key ' || coalesce(f.account_key, 'NULL') || ' is not in dim_account and is not the unknown member -1' as reason
    from {{ ref('fct_transactions') }} f
    left join {{ ref('dim_account') }} d
        on d.account_key = f.account_key
    where d.account_key is null
      and coalesce(f.account_key, '') <> '-1'
),

orphan_customer as (
    select
        'FCT_TRANSACTIONS' as object_name,
        f.transaction_id::varchar as business_key,
        'ORPHAN_FACT' as violation_type,
        'customer_key ' || coalesce(f.customer_key, 'NULL') || ' is not in dim_customer and is not the unknown member -1' as reason
    from {{ ref('fct_transactions') }} f
    left join {{ ref('dim_customer') }} d
        on d.customer_key = f.customer_key
    where d.customer_key is null
      and coalesce(f.customer_key, '') <> '-1'
),

orphan_branch as (
    select
        'FCT_TRANSACTIONS' as object_name,
        f.transaction_id::varchar as business_key,
        'ORPHAN_FACT' as violation_type,
        'branch_key ' || coalesce(f.branch_key, 'NULL') || ' is not in dim_branch and is not the unknown member -1' as reason
    from {{ ref('fct_transactions') }} f
    left join {{ ref('dim_branch') }} d
        on d.branch_key = f.branch_key
    where d.branch_key is null
      and coalesce(f.branch_key, '') <> '-1'
),

unknown_account_missing as (
    select
        'FCT_TRANSACTIONS' as object_name,
        f.transaction_id::varchar as business_key,
        'UNKNOWN_MEMBER_MISSING' as violation_type,
        'account_key is the unknown member -1 but dim_account has no such row' as reason
    from {{ ref('fct_transactions') }} f
    where f.account_key = '-1'
      and not exists (
          select 1 from {{ ref('dim_account') }} d where d.account_key = '-1'
      )
),

unknown_customer_missing as (
    select
        'FCT_TRANSACTIONS' as object_name,
        f.transaction_id::varchar as business_key,
        'UNKNOWN_MEMBER_MISSING' as violation_type,
        'customer_key is the unknown member -1 but dim_customer has no such row' as reason
    from {{ ref('fct_transactions') }} f
    where f.customer_key = '-1'
      and not exists (
          select 1 from {{ ref('dim_customer') }} d where d.customer_key = '-1'
      )
),

unknown_branch_missing as (
    select
        'FCT_TRANSACTIONS' as object_name,
        f.transaction_id::varchar as business_key,
        'UNKNOWN_MEMBER_MISSING' as violation_type,
        'branch_key is the unknown member -1 but dim_branch has no such row' as reason
    from {{ ref('fct_transactions') }} f
    where f.branch_key = '-1'
      and not exists (
          select 1 from {{ ref('dim_branch') }} d where d.branch_key = '-1'
      )
)

select * from duplicate_transaction
union all
select * from duplicate_branch
union all
select * from duplicate_customer_version
union all
select * from orphan_account
union all
select * from orphan_customer
union all
select * from orphan_branch
union all
select * from unknown_account_missing
union all
select * from unknown_customer_missing
union all
select * from unknown_branch_missing
