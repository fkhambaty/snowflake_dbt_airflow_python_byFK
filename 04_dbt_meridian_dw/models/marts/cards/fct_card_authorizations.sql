{{ config(materialized='table', tags=['microbatch', 'hot_path'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}}) }}

/*
    fct_card_authorizations — transaction fact at authorization grain.

    Rebuilt in full on the micro-batch, on purpose. The fraud rules are window
    calculations (auths in the last 10 minutes, amount versus the card's own
    recent average). An incremental slice cannot see the card's previous rows,
    so the windows would be wrong. This table stays far smaller than
    fct_transactions, which is the one that must be incremental.

    fraud_label / fraud_pattern are the synthetic ground truth for evaluation.
    They are not inputs to the rules.
*/

with auths as (
    select * from {{ ref('stg_postgres__card_authorizations') }}
),
windowed as (
    select
        a.*,
        to_date(a.auth_ts) as auth_date,
        count(*) over (
            partition by a.card_id
            order by date_part(epoch_second, a.auth_ts)
            range between 600 preceding and current row
        ) as auths_in_10m,
        avg(a.amount) over (
            partition by a.card_id
            order by a.auth_ts
            rows between 30 preceding and 1 preceding
        ) as avg_prior_amount
    from auths a
),
customers as (
    select customer_key, customer_id, country_code, valid_from, valid_to
    from {{ ref('dim_customer') }}
    where customer_id <> -1
)

select
    w.authorization_id,
    {{ date_key('w.auth_ts') }}                              as date_key,
    coalesce(dc.customer_key, '-1')                          as customer_key,
    coalesce(card.card_key, '-1')                            as card_key,
    coalesce(dm.merchant_key, '-1')                          as merchant_key,
    coalesce(ds.sale_event_key, '-1')                        as sale_event_key,
    coalesce(db.branch_key, '-1')                            as branch_key,
    coalesce(dcur.currency_key, '-1')                        as currency_key,
    w.customer_id,
    w.card_id,
    w.merchant_id,
    w.auth_ts,
    w.auth_date,
    w.amount                                                 as amount_local,
    w.amount * coalesce(fx.rate_to_reporting, 1)             as amount_reporting,
    coalesce(fx.rate_to_reporting, 1)                        as fx_rate_to_reporting,
    w.entry_mode,
    w.card_present,
    w.response,
    w.decline_reason,
    dm.marketplace,
    dm.is_marketplace,
    dm.category_group,
    w.merchant_country,
    dc.country_code                                          as customer_country,
    ds.event_name                                            as sale_event_name,
    w.auths_in_10m,
    w.avg_prior_amount,
    card.credit_limit,
    w.auths_in_10m >= 4                                      as is_velocity,
    (w.merchant_country <> dc.country_code and not w.card_present) as is_geo_mismatch,
    (
        w.amount > 4 * coalesce(w.avg_prior_amount, w.amount)
        and card.credit_limit > 0
        and w.amount > card.credit_limit * 0.5
    )                                                        as is_high_amount,
    (w.amount <= 5 and w.auths_in_10m >= 4)                  as is_card_testing,
    (
        w.auths_in_10m >= 4
        or (w.merchant_country <> dc.country_code and not w.card_present)
        or (
            w.amount > 4 * coalesce(w.avg_prior_amount, w.amount)
            and card.credit_limit > 0
            and w.amount > card.credit_limit * 0.5
        )
        or (w.amount <= 5 and w.auths_in_10m >= 4)
    )                                                        as is_rule_suspect,
    w.fraud_label,
    w.fraud_pattern,
    w._extracted_at
from windowed w
left join customers dc
       on dc.customer_id = w.customer_id
      and {{ scd2_match('w.auth_ts', 'dc') }}
left join {{ ref('dim_card') }} card on card.card_id = w.card_id
left join {{ ref('dim_merchant') }} dm on dm.merchant_id = w.merchant_id
left join {{ ref('dim_branch') }} db on db.branch_id = card.branch_id
left join {{ ref('dim_currency') }} dcur on dcur.currency_code = w.currency_code
left join {{ ref('dim_sale_event') }} ds
       on ds.marketplace = dm.marketplace
      and ds.country_code = 'IN'
      and w.auth_date between ds.starts_on and ds.ends_on
left join {{ ref('int_fx_rates_daily_filled') }} fx
       on fx.currency_code = w.currency_code
      and fx.date_day = w.auth_date
qualify row_number() over (
    partition by w.authorization_id
    order by ds.starts_on nulls last
) = 1
