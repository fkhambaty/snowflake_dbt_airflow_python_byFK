{{ config(tags=['completeness']) }}

/*
    Every key bronze delivered is present in staging, for every source table.
    A failing row names the table and the missing key. Runs in the daily build only:
    reading every bronze key every five minutes would cost more than it protects.
*/

{%- set tables = [
    ('stg_postgres__currencies',          'postgres_ref',  'currencies',          ['currency_code'],    none),
    ('stg_postgres__countries',           'postgres_ref',  'countries',           ['country_code'],     none),
    ('stg_postgres__fx_rates',            'postgres_ref',  'fx_rates',            ['fx_rate_id'],       none),
    ('stg_postgres__channels',            'postgres_ref',  'channels',            ['channel_id'],       none),
    ('stg_postgres__products',            'postgres_ref',  'products',            ['product_id'],       none),
    ('stg_postgres__merchants',           'postgres_ref',  'merchants',           ['merchant_id'],      none),
    ('stg_postgres__sale_events',         'postgres_ref',  'sale_events',         ['sale_event_id'],    none),
    ('stg_postgres__offer_catalog',       'postgres_ref',  'offer_catalog',       ['offer_code'],       none),
    ('stg_postgres__branches',            'postgres_core', 'branches',            ['branch_id'],        none),
    ('stg_postgres__employees',           'postgres_core', 'employees',           ['employee_id'],      none),
    ('stg_postgres__customers',           'postgres_core', 'customers',           ['customer_id'],      none),
    ('stg_postgres__accounts',            'postgres_core', 'accounts',            ['account_id'],       none),
    ('stg_postgres__account_holders',     'postgres_core', 'account_holders',     ['account_id', 'customer_id'], none),
    ('stg_postgres__transactions',        'postgres_core', 'transactions',        ['transaction_id'],   'record:transaction_ts::timestamp_ntz'),
    ('stg_postgres__loan_applications',   'postgres_core', 'loan_applications',   ['application_id'],   none),
    ('stg_postgres__customer_features',   'postgres_core', 'customer_features',   ['customer_id'],      none),
    ('stg_postgres__card_applications',   'postgres_core', 'card_applications',   ['application_id'],   none),
    ('stg_postgres__credit_cards',        'postgres_core', 'credit_cards',        ['card_id'],          none),
    ('stg_postgres__card_authorizations', 'postgres_core', 'card_authorizations', ['authorization_id'], none),
] -%}

{% for staging_model, source_name, table_name, key_columns, dev_ts in tables %}
{{ missing_from_staging(ref(staging_model), source(source_name, table_name), table_name, key_columns, dev_ts) }}
{% if not loop.last %}union all{% endif %}
{% endfor %}
