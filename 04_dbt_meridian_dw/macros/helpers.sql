{# ------------------------------------------------------------------------------------
   limit_in_dev(column)
   In dev, only build the last N days of a big table. Same SQL, 10x cheaper iterations.
   Unit tests keep the dates in their fixtures, so this filter does not apply there.
   Usage:  where 1=1 {{ limit_in_dev('transaction_ts') }}
------------------------------------------------------------------------------------ #}
{% macro limit_in_dev(ts_column) -%}
    {%- if target.name != 'prod' and model.resource_type != 'unit_test' -%}
        and {{ ts_column }} >= dateadd('day', -{{ var('dev_days_of_history') }}, current_timestamp())
    {%- endif -%}
{%- endmacro %}


{# ------------------------------------------------------------------------------------
   scd2_match(ts_expr, dim_alias)
   The point-in-time join predicate. Forgetting it is THE classic fan-out bug
   (demonstrated in 06_performance_lab/04_join_explosion_scd2.sql).
------------------------------------------------------------------------------------ #}
{% macro scd2_match(ts_expr, dim_alias) -%}
    {{ ts_expr }} >= {{ dim_alias }}.valid_from and {{ ts_expr }} < {{ dim_alias }}.valid_to
{%- endmacro %}


{# ------------------------------------------------------------------------------------
   date_key(ts_expr) -> integer yyyymmdd, the join key into dim_date
------------------------------------------------------------------------------------ #}
{% macro date_key(ts_expr) -%}
    to_number(to_char(to_date({{ ts_expr }}), 'YYYYMMDD'))
{%- endmacro %}


{# ------------------------------------------------------------------------------------
   is_credit(txn_type_expr) -> boolean: does this transaction type increase the balance?
   Single source of truth for direction; the seed transaction_type_mapping mirrors it.
------------------------------------------------------------------------------------ #}
{% macro is_credit(txn_type_expr) -%}
    {{ txn_type_expr }} in ('DEPOSIT', 'TRANSFER_IN', 'INTEREST', 'SALARY_CREDIT', 'REFUND')
{%- endmacro %}


{# ------------------------------------------------------------------------------------
   grant_schema_usage(schemas)   on-run-end
   dbt's `grants:` config grants SELECT on each relation. A role also needs USAGE on the
   schema. Only the prod MARTS schema is opened to consumers; staging stays private.
------------------------------------------------------------------------------------ #}
{% macro grant_schema_usage(schemas) %}
    {% if execute and target.name == 'prod' %}
        {% for schema in schemas if schema | upper == 'MARTS' %}
            {% for role in var('mart_readers') %}
                {% do run_query('grant usage on schema ' ~ target.database ~ '.' ~ schema ~ ' to role ' ~ role) %}
            {% endfor %}
        {% endfor %}
    {% endif %}
    select 1
{% endmacro %}


{# ------------------------------------------------------------------------------------
   apply_hard_deletes(source_table_name, pk_column)
   Post-hook for incremental models: remove rows whose PK appears in the Postgres delete log.
   A MERGE cannot delete rows it never sees, so deletes need an explicit step.
------------------------------------------------------------------------------------ #}
{% macro apply_hard_deletes(source_table_name, pk_column) -%}
    {%- if is_incremental() -%}
    delete from {{ this }}
    where {{ pk_column }} in (
        select try_to_number(pk_value)
        from {{ ref('stg_postgres__deleted_records') }}
        where table_name = '{{ source_table_name }}'
    )
    {%- else -%}
    select 1
    {%- endif -%}
{%- endmacro %}


{# A deleted transaction must leave the search index too. Scoped to entity_type so an
   account whose id happens to equal a deleted transaction id is not removed. #}
{% macro prune_omni_search_deletes() -%}
    {%- if is_incremental() -%}
    delete from {{ this }}
    where entity_type = 'TRANSACTION'
      and try_to_number(entity_id) in (
          select try_to_number(pk_value)
          from {{ ref('stg_postgres__deleted_records') }}
          where table_name = 'transactions'
      )
    {%- else -%}
    select 1
    {%- endif -%}
{%- endmacro %}


{# ------------------------------------------------------------------------------------
   not_deleted(source_table_name, pk_expr)
   WHERE-clause fragment for view-materialised staging models: hide rows the source deleted.
------------------------------------------------------------------------------------ #}
{% macro not_deleted(source_table_name, pk_expr) -%}
    not exists (
        select 1
        from {{ ref('stg_postgres__deleted_records') }} d
        where d.table_name = '{{ source_table_name }}'
          and d.pk_value = {{ pk_expr }}::string
    )
{%- endmacro %}


{# ------------------------------------------------------------------------------------
   print_pipeline_health()   dbt run-operation print_pipeline_health
   Prints the ingestion control view so Airflow logs show end-to-end lag after every batch.
------------------------------------------------------------------------------------ #}
{% macro print_pipeline_health() %}
    {% if execute %}
        {% set results = run_query("select table_name, minutes_behind_source, last_status, last_rows from MERIDIAN_RAW.CONTROL.V_PIPELINE_HEALTH order by 2 desc") %}
        {{ log('table                        | min behind | status      | rows', info=True) }}
        {% for row in results.rows %}
            {{ log((row[0] ~ '                            ')[:28] ~ ' | ' ~ row[1] ~ ' | ' ~ row[2] ~ ' | ' ~ row[3], info=True) }}
        {% endfor %}
    {% endif %}
{% endmacro %}


{# SLO gate used by Airflow. Only the four tables on the 5-minute path are checked;
   daily reference/master tables intentionally have a different freshness target. #}
{% macro assert_pipeline_health(max_minutes=15) %}
    {% if execute %}
        {% set sql %}
            select table_name, minutes_behind_source, last_status
            from MERIDIAN_RAW.CONTROL.V_PIPELINE_HEALTH
            where table_name in (
                'core.transactions',
                'core.card_applications',
                'core.card_authorizations',
                'cdc.deleted_records'
            )
              and (
                    minutes_behind_source > {{ max_minutes }}
                 or coalesce(last_status, 'MISSING') not in ('SUCCESS', 'NO_CHANGES')
              )
            order by minutes_behind_source desc
        {% endset %}
        {% set failures = run_query(sql) %}
        {% if failures is not none and failures.rows | length > 0 %}
            {% for row in failures.rows %}
                {{ log('SLO FAILURE ' ~ row[0] ~ ': lag=' ~ row[1] ~ ' minutes, status=' ~ row[2], info=True) }}
            {% endfor %}
            {{ exceptions.raise_compiler_error(
                'Hot-path freshness SLO failed for ' ~ (failures.rows | length)
                ~ ' table(s); threshold=' ~ max_minutes ~ ' minutes.'
            ) }}
        {% endif %}
        {{ log('Hot-path freshness SLO passed (maximum ' ~ max_minutes ~ ' minutes).', info=True) }}
    {% endif %}
{% endmacro %}


{# ------------------------------------------------------------------------------------
   drop_ci_schemas(prefix)   dbt run-operation drop_ci_schemas --args "{prefix: dbt_ci_pr_42}"
   Removes every schema the slim-CI run created (prefix_staging, prefix_marts, ...).
------------------------------------------------------------------------------------ #}
{% macro drop_ci_schemas(prefix) %}
    {% if execute %}
        {% set schemas = run_query("select schema_name from " ~ target.database ~ ".information_schema.schemata where schema_name ilike '" ~ prefix ~ "%'") %}
        {% for row in schemas.rows %}
            {{ log('dropping schema ' ~ target.database ~ '.' ~ row[0], info=True) }}
            {% do run_query("drop schema if exists " ~ target.database ~ "." ~ row[0] ~ " cascade") %}
        {% endfor %}
    {% endif %}
{% endmacro %}


{# ------------------------------------------------------------------------------------
   unknown_member_row(columns)  -> a SELECT that produces the Kimball "unknown" row (-1)
   columns: list of {name, type, value}
------------------------------------------------------------------------------------ #}
{% macro unknown_member_select(columns) -%}
    select
    {%- for c in columns %}
        {{ c.value }}::{{ c.type }} as {{ c.name }}{{ "," if not loop.last }}
    {%- endfor %}
{%- endmacro %}
