{#
  Environment-aware schema naming (interview favourite: "how do you isolate dev from prod in dbt?")

    target.name == 'prod'       -> MERIDIAN_ANALYTICS.STAGING / INTERMEDIATE / MARTS
    target.name == 'dev_clone'  -> cloned database, same schema names; replacing is isolated
    anything else               -> DBT_FK_STAGING / DBT_FK_MARTS (target.schema prefix)

  Without this override dbt would build prod models into ANALYTICS_STAGING etc.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- elif target.name in ['prod', 'dev_clone'] -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
