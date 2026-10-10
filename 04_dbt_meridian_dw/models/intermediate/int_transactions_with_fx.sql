/*
    Transactions + direction + reporting-currency conversion at the TRANSACTION-DATE rate.

    Currency rule (Kimball ch. "Multiple currencies"): store the local amount AND the standard
    (group reporting) amount on the same fact row, plus the rate used. Never convert at query
    time with "today's" rate - history must not move when the rate moves.
*/

with txns as (
    select * from {{ ref('stg_postgres__transactions') }}
),

fx as (
    select date_day, currency_code, rate_to_reporting, is_forward_filled
    from {{ ref('int_fx_rates_daily_filled') }}
),

holders as (
    select * from {{ ref('int_account_primary_holder') }}
),

final as (
    select
        t.transaction_id,
        t.account_id,
        h.primary_customer_id,
        t.transaction_ts,
        t.transaction_date,
        t.transaction_type,
        {{ is_credit('t.transaction_type') }}                    as is_credit,
        t.status,
        t.amount                                                  as amount_local,
        t.currency_code,
        fx.rate_to_reporting                                      as fx_rate_to_reporting,
        fx.is_forward_filled                                      as fx_is_forward_filled,
        round(t.amount * fx.rate_to_reporting, 2)                 as amount_reporting,
        iff({{ is_credit('t.transaction_type') }}, t.amount, -t.amount)                               as signed_amount_local,
        iff({{ is_credit('t.transaction_type') }}, 1, -1) * round(t.amount * fx.rate_to_reporting, 2) as signed_amount_reporting,
        t.channel_id,
        t.branch_id,
        t.employee_id,
        t.counterparty_account,
        t.merchant_category,
        t.reference_no,
        t.description,
        t.created_at,
        t.updated_at,
        t._extracted_at
    from txns t
    left join holders h on h.account_id = t.account_id
    left join fx on fx.date_day = t.transaction_date and fx.currency_code = t.currency_code
)

select * from final
