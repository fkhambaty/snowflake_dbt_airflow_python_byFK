-- Singular test: the fact must contain exactly the transactions staging has - no fan-out, no loss.
-- A fan-out from a broken SCD2 join (missing valid_from/valid_to predicate) shows up here first.
-- Returns rows = failure.
with s as (
    select count(*) as n, sum(amount) as amt from {{ ref('stg_postgres__transactions') }}
),
f as (
    select count(*) as n, sum(amount_local) as amt from {{ ref('fct_transactions') }}
)
select s.n as staging_rows, f.n as fact_rows, s.amt as staging_amount, f.amt as fact_amount
from s cross join f
where s.n <> f.n or abs(coalesce(s.amt, 0) - coalesce(f.amt, 0)) > 0.01
