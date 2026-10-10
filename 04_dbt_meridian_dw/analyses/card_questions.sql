-- Same four questions the semantic view ships as verified queries.
-- dbt compile, then paste into Snowsight. This path does not need Cortex Analyst.

-- 1. Approved marketplace spend inside a published sale window
select marketplace, sale_event_name,
       sum(amount_reporting) as card_spend_usd,
       count(*) as authorizations
from {{ ref('fct_card_authorizations') }}
where response = 'APPROVED'
  and marketplace is not null
  and sale_event_name is not null
group by 1, 2
order by 1, 2;

-- 2. Approval rate by the segment frozen on the application, not today's segment
select segment_at_apply,
       count(*) as applications,
       avg(iff(decision = 'APPROVED', 1, 0)) as approval_rate
from {{ ref('fct_card_applications') }}
group by 1
order by 3 desc;

-- 3. Who to contact, and the sentence a human can defend
select offer_name, sale_event_name, reason, count(*) as customers,
       round(avg(propensity_score), 3) as avg_propensity
from {{ ref('fct_next_best_offer') }}
group by 1, 2, 3
order by customers desc;

-- 4. Fraud queue by which rule fired (a row can trip more than one; this picks a priority)
select
    case
        when is_velocity then 'VELOCITY'
        when is_geo_mismatch then 'GEO_MISMATCH'
        when is_high_amount then 'HIGH_AMOUNT'
        when is_card_testing then 'CARD_TESTING'
    end as rule_name,
    count(*) as authorizations
from {{ ref('fct_card_authorizations') }}
where is_rule_suspect
group by 1
order by 2 desc;
