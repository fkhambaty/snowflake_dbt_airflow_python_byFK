{{ config(materialized='table', tags=['daily'],
    meta={'governance': {'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'}}}) }}

/*
    fct_next_best_offer — one recommended action per customer, or no row.
    The model score is an input. The decision is this SQL, so a reviewer can
    read why someone was contacted. A blocked card or a recent rule-suspect
    authorization suppresses every offer.
*/

with people as (
    select
        c.customer_key,
        c.customer_id,
        c.segment,
        c.risk_rating,
        c.kyc_status,
        c.tenure_months,
        c.country_code
    from {{ ref('dim_customer_current') }} c
),
features as (
    -- the same table the propensity model was trained on
    select * from {{ ref('ml_customer_features') }}
),
model_score as (
    select entity_id as customer_id, score
    from {{ ref('stg_ml__model_scores') }}
    where model_name = 'card_propensity_v1' and entity_type = 'CUSTOMER'
),
blocked as (
    select distinct customer_id
    from {{ ref('fct_card_authorizations') }}
    where is_rule_suspect
      and auth_ts >= dateadd('day', -30, current_timestamp())
),
spend as (
    select customer_id, marketplace, sum(amount_reporting) as spend
    from {{ ref('fct_card_authorizations') }}
    where marketplace is not null
      and response = 'APPROVED'
      and auth_ts >= dateadd('day', -180, current_timestamp())
    group by 1, 2
),
dominant as (
    select customer_id, marketplace
    from spend
    qualify row_number() over (partition by customer_id order by spend desc) = 1
),
upcoming as (
    select marketplace, event_name, starts_on, ends_on
    from {{ ref('dim_sale_event') }}
    where country_code = 'IN'
      and sale_event_id <> -1
      and ends_on >= current_date()
      and starts_on <= dateadd('day', 21, current_date())
),
scored as (
    select
        p.*,
        f.has_active_card,
        f.has_blocked_card,
        f.utilization,
        d.marketplace as dominant_marketplace,
        coalesce(
            m.score,
            1 / (1 + exp(-{{ card_policy_logit(
                'f.estimated_annual_income', 'f.avg_monthly_balance', 'f.salary_credits_3m',
                'f.tenure_months', 'f.age_years', 'f.risk_rating'
            ) }}))
        ) as propensity_score,
        iff(m.score is null, 'RULE', 'MODEL') as score_source,
        b.customer_id is not null as fraud_blocked
    from people p
    left join features f on f.customer_id = p.customer_id
    left join model_score m on m.customer_id = p.customer_id
    left join dominant d on d.customer_id = p.customer_id
    left join blocked b on b.customer_id = p.customer_id
    where f.customer_id is not null
),
chosen as (
    select
        s.*,
        case
            when s.has_blocked_card or s.fraud_blocked then null
            when not s.has_active_card
                 and s.propensity_score >= 0.60
                 and s.risk_rating <> 'HIGH'
                 and s.kyc_status = 'VERIFIED'
                 and s.dominant_marketplace is null
                then 'ACQ_FEE_WAIVE'
            when s.has_active_card
                 and s.dominant_marketplace = 'FLIPKART'
                 and exists (select 1 from upcoming u where u.marketplace = 'FLIPKART')
                then 'FLIPKART_CASHBACK_5'
            when s.has_active_card
                 and s.dominant_marketplace = 'AMAZON'
                 and exists (select 1 from upcoming u where u.marketplace = 'AMAZON')
                then 'AMAZON_CASHBACK_5'
            when not s.has_active_card
                 and s.propensity_score >= 0.60
                 and s.risk_rating <> 'HIGH'
                 and s.kyc_status = 'VERIFIED'
                then 'ACQ_FEE_WAIVE'
            when s.has_active_card
                 and coalesce(s.utilization, 1) < 0.25
                 and s.tenure_months >= 12
                 and s.risk_rating = 'LOW'
                 and not s.fraud_blocked
                then 'LIMIT_REVIEW'
        end as offer_code
    from scored s
)

select
    c.customer_id,
    c.customer_key,
    c.offer_code,
    o.offer_name,
    o.offer_family,
    o.marketplace,
    o.cashback_rate,
    c.propensity_score,
    c.score_source,
    c.segment,
    c.risk_rating,
    c.has_active_card,
    c.dominant_marketplace,
    u.event_name as sale_event_name,
    u.starts_on  as sale_starts_on,
    case c.offer_code
        when 'ACQ_FEE_WAIVE' then 'Looks like customers we already approve, and has no active card'
        when 'FLIPKART_CASHBACK_5' then 'Own Flipkart spend dominates, and a Flipkart sale is inside 21 days'
        when 'AMAZON_CASHBACK_5' then 'Own Amazon spend dominates, and an Amazon sale is inside 21 days'
        when 'LIMIT_REVIEW' then 'Low utilisation, low risk, tenure over a year — a human still confirms'
    end as reason,
    current_date() as recommended_on
from chosen c
join {{ ref('dim_offer') }} o on o.offer_code = c.offer_code and o.is_active
left join upcoming u on u.marketplace = o.marketplace
qualify row_number() over (
    partition by c.customer_id
    order by u.starts_on nulls last
) = 1
