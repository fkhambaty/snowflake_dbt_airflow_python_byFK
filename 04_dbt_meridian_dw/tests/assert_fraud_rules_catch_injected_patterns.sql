-- A burst is caught when a later authorization in the cluster trips the rule.
-- The first tap of a four-tap card test is not a pattern yet; the fourth tap is.
select fraud_pattern, recall
from (
    select fraud_pattern, avg(caught) as recall
    from (
        select
            fraud_pattern,
            card_id,
            max(iff(is_rule_suspect, 1, 0)) as caught
        from {{ ref('fct_card_authorizations') }}
        where fraud_label
        group by 1, 2
    ) per_card
    group by 1
) by_pattern
where recall < 0.7
