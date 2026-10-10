{{ config(materialized='table', tags=['daily']) }}

/*
    fct_fx_rates_daily - a "factless-ish" daily rate fact so analysts can re-convert any
    amount at any date without touching the intermediate layer.
    Grain: one row per day per currency.
*/

select
    {{ date_key('f.date_day') }}                                   as date_key,
    f.date_day,
    coalesce(c.currency_key, '-1')                                 as currency_key,
    f.currency_code,
    f.reporting_currency,
    f.rate_to_reporting,
    1 / f.rate_to_reporting                                        as rate_from_reporting,
    f.rate_source_date,
    f.rate_age_days,
    f.is_forward_filled
from {{ ref('int_fx_rates_daily_filled') }} f
left join {{ ref('dim_currency') }} c on c.currency_code = f.currency_code
