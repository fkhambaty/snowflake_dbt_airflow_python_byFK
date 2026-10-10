{{ config(materialized='table', tags=['daily']) }}

/*
    Conformed date dimension. Generated, not loaded. Integer yyyymmdd key so facts can be
    partitioned/clustered on it and humans can read it in a query profile.
    Fiscal year: India-style April-March for the group (var it if your bank differs).
*/

with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="to_date('" ~ var('date_spine_start') ~ "')",
        end_date="to_date('" ~ var('date_spine_end') ~ "')"
    ) }}
),

dates as (
    select to_date(date_day) as date_day from spine
)

select
    {{ date_key('date_day') }}                                   as date_key,
    date_day,
    year(date_day)                                               as year_number,
    quarter(date_day)                                            as quarter_number,
    'Q' || quarter(date_day)                                     as quarter_name,
    month(date_day)                                              as month_number,
    monthname(date_day)                                          as month_short_name,
    to_char(date_day, 'YYYY-MM')                                 as year_month,
    day(date_day)                                                as day_of_month,
    dayofweekiso(date_day)                                       as iso_day_of_week,
    dayname(date_day)                                            as day_short_name,
    weekiso(date_day)                                            as iso_week_number,
    date_trunc('week', date_day)::date                           as week_start_date,
    date_trunc('month', date_day)::date                          as month_start_date,
    last_day(date_day)                                           as month_end_date,
    date_day = last_day(date_day)                                as is_month_end,
    dayofweekiso(date_day) in (6, 7)                             as is_weekend,
    dayofweekiso(date_day) not in (6, 7)                         as is_business_day,
    iff(month(date_day) >= 4, year(date_day) + 1, year(date_day)) as fiscal_year,
    iff(month(date_day) >= 4, quarter(date_day) - 1, quarter(date_day) + 3) as fiscal_quarter,
    date_day = current_date()                                    as is_today,
    date_day < current_date()                                    as is_past
from dates

union all

-- unknown member: facts with an unparseable date still join
select -1, '1900-01-01'::date, 1900, 1, 'Q1', 1, 'Jan', '1900-01', 1, 1, 'Mon', 1,
       '1900-01-01'::date, '1900-01-01'::date, '1900-01-31'::date, false, false, true, 1900, 4, false, true
