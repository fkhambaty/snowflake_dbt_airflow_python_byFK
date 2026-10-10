{{ config(materialized='table', tags=['daily'],
    grants={'select': ['MERIDIAN_ANALYST', 'MERIDIAN_ML', 'MERIDIAN_APP', 'MERIDIAN_CEO', 'MERIDIAN_BRANCH_MANAGER', 'MERIDIAN_STAFF']},
    meta={'governance': {'row_access': {'policy': 'RAP_BRANCH_INTERNAL', 'column': 'branch_id'}}}) }}

-- SCD Type 1. Only branch-counter transactions carry an employee; everything else -> unknown member.
with employees as (
    select * from {{ ref('stg_postgres__employees') }}
),

branches as (
    select branch_id, branch_code, branch_name from {{ ref('stg_postgres__branches') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['e.employee_id']) }} as employee_key,
    e.employee_id,
    e.employee_code,
    e.full_name,
    e.job_title,
    e.branch_id,
    b.branch_code,
    b.branch_name,
    e.hire_date,
    e.is_active
from employees e
left join branches b on b.branch_id = e.branch_id

union all

select '-1', -1, 'UNKNOWN', 'No employee (digital/system)', 'NONE', -1, 'UNKNOWN', 'Unknown branch', '1900-01-01'::date, false
