{{ config(materialized='table', tags=['daily'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}, 'pii': {'income_at_apply': 'income', 'balance_at_apply': 'income', 'salary_credits_3m_at_apply': 'income'}}}) }}

/*
    fct_card_applications — accumulating snapshot.
    One row per application. Features are the values frozen at apply time.
    policy_probability recomputes the published policy. It is not the label.
*/

with apps as (
    select * from {{ ref('stg_postgres__card_applications') }}
),
customers as (
    select customer_key, customer_id, valid_from, valid_to
    from {{ ref('dim_customer') }}
    where customer_id <> -1
),
scores as (
    select entity_id as application_id, score as model_probability, score_band, explanation
    from {{ ref('stg_ml__model_scores') }}
    where model_name = 'card_decision_v1' and entity_type = 'APPLICATION'
)

select
    a.application_id,
    {{ date_key('a.applied_at') }}                         as applied_date_key,
    coalesce(dc.customer_key, '-1')                        as customer_key,
    coalesce(dp.product_key, '-1')                         as product_key,
    coalesce(db.branch_key, '-1')                          as branch_key,
    a.customer_id,
    a.channel_code,
    a.applied_at,
    a.decided_at,
    datediff('hour', a.applied_at, a.decided_at)           as hours_to_decision,
    a.decision,
    a.decision_reason,
    a.limit_offered,
    a.currency_code,
    a.segment_at_apply,
    a.risk_rating_at_apply,
    a.age_years_at_apply,
    a.tenure_months_at_apply,
    a.income_at_apply,
    a.balance_at_apply,
    a.salary_credits_3m_at_apply,
    1 / (1 + exp(-{{ card_policy_logit(
        'a.income_at_apply', 'a.balance_at_apply', 'a.salary_credits_3m_at_apply',
        'a.tenure_months_at_apply', 'a.age_years_at_apply', 'a.risk_rating_at_apply'
    ) }}))                                                 as policy_probability,
    s.model_probability,
    s.score_band                                           as model_band,
    s.explanation                                          as model_explanation
from apps a
left join customers dc
       on dc.customer_id = a.customer_id
      and {{ scd2_match('a.applied_at', 'dc') }}
left join {{ ref('dim_product') }} dp on dp.product_id = a.product_id
left join {{ ref('dim_branch') }} db on db.branch_id = a.branch_id
left join scores s on s.application_id = a.application_id
