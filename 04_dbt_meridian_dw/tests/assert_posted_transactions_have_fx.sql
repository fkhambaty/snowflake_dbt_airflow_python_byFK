-- Singular test: every POSTED transaction in a non-reporting currency must have been converted.
-- If this fails, treasury stopped publishing or a new currency appeared without rates.
select transaction_id, transaction_date, currency_code
from {{ ref('fct_transactions') }}
where status = 'POSTED'
  and amount_reporting is null
  and currency_code <> '{{ var("reporting_currency") }}'
