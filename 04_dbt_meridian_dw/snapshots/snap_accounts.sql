{% snapshot snap_accounts %}

{{
    config(
        unique_key='account_id',
        strategy='check',
        check_cols=['product_id', 'branch_id', 'currency_code', 'account_status', 'closed_date', 'credit_limit', 'interest_rate'],
        hard_deletes='invalidate'
    )
}}

/*
    WHY 'check' AND NOT 'timestamp' HERE (interview gold):
      accounts.updated_at is bumped by EVERY balance change, i.e. by every transaction.
      A timestamp strategy would create a new SCD2 version per transaction = millions of
      useless versions. The 'check' strategy only versions when one of the listed
      attribute columns actually changes. current_balance is excluded on purpose:
      balances are measures and belong in facts (fct_daily_account_balance), not dimensions.

      Trade-off: dbt_valid_from becomes the snapshot run time, not the source change time.
      Snapshot frequency (daily in our Airflow DAG) therefore bounds the SCD2 precision.
*/

select
    account_id,
    account_number,
    product_id,
    branch_id,
    currency_code,
    account_status,
    opened_date,
    closed_date,
    credit_limit,
    interest_rate,
    created_at
from {{ ref('stg_postgres__accounts') }}

{% endsnapshot %}
