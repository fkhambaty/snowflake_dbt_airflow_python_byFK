{{ config(materialized='view', tags=['daily']) }}

-- One row per customer, the version that is true now.
-- Cortex Analyst must not see every SCD2 version or "how many customers" double-counts.
select *
from {{ ref('dim_customer') }}
where is_current
  and customer_id <> -1
