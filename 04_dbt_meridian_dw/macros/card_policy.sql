-- Keep these weights identical to core.card_policy_logit in 07_ddl_cards.sql.
-- The function is the bank's policy. This macro is the warehouse copy used when
-- the Python model has not scored a customer yet.

{% macro card_policy_logit(income, balance, salary, tenure, age, risk) -%}
(
    -1.1
    + 1.3 * least({{ income }} / 2000000.0, 2)
    + 0.8 * least({{ balance }} / 200000.0, 2)
    + 0.9 * least({{ salary }} / 300000.0, 2)
    + 0.6 * (case when {{ tenure }} >= 12 then 1 when {{ tenure }} >= 6 then 0.5 else 0 end)
    - (case {{ risk }} when 'HIGH' then 1.2 when 'MEDIUM' then 0.4 else 0 end)
    - (case when {{ age }} < 23 then 0.4 else 0 end)
)
{%- endmacro %}
