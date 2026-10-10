/*
    Daily FX grid with no gaps: every calendar day x every currency -> rate to reporting currency.

    Treasury publishes rates on business days only. A Saturday card payment in Dubai must still
    be converted, and the accepted rule is "use the last published rate" (forward fill).

    Technique: date spine  x  currency list  ->  LEFT JOIN actual rates  ->  LAST_VALUE(... IGNORE NULLS)
*/

with currencies as (
    select currency_code from {{ ref('stg_postgres__currencies') }}
),

rates as (
    select rate_date, from_currency, rate, rate_source
    from {{ ref('stg_postgres__fx_rates') }}
    where to_currency = '{{ var("reporting_currency") }}'
),

bounds as (
    select min(rate_date) as start_date from rates
),

spine as (
    select d.date_day
    from {{ ref('dim_date') }} d
    cross join bounds b
    where d.date_day between b.start_date and current_date()
),

grid as (
    select s.date_day, c.currency_code
    from spine s
    cross join currencies c
),

joined as (
    select
        g.date_day,
        g.currency_code,
        case when g.currency_code = '{{ var("reporting_currency") }}' then 1.0 else r.rate end as published_rate,
        r.rate_source,
        iff(g.currency_code = '{{ var("reporting_currency") }}', g.date_day, r.rate_date) as published_rate_date
    from grid g
    left join rates r
           on r.rate_date = g.date_day
          and r.from_currency = g.currency_code
),

filled as (
    select
        date_day,
        currency_code,
        published_rate,
        last_value(published_rate ignore nulls) over (
            partition by currency_code order by date_day
            rows between unbounded preceding and current row
        )                                                   as rate_to_reporting,
        last_value(published_rate_date ignore nulls) over (
            partition by currency_code order by date_day
            rows between unbounded preceding and current row
        )                                                   as rate_source_date,
        published_rate is null                              as is_forward_filled
    from joined
)

select
    date_day,
    currency_code,
    '{{ var("reporting_currency") }}'   as reporting_currency,
    rate_to_reporting,
    rate_source_date,
    datediff('day', rate_source_date, date_day) as rate_age_days,
    is_forward_filled
from filled
where rate_to_reporting is not null      -- days before the very first publication cannot be filled
