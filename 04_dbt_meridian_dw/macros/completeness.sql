{# ------------------------------------------------------------------------------------
   missing_from_staging(staging_model, bronze_source, table_name, key_columns, dev_ts=none)

   Keys that bronze says must exist in staging but staging does not have.
     expected = distinct keys in bronze
                - keys in the Postgres delete log (staging removes those on purpose)
                - rows that arrived after staging last read bronze (incremental lag)
                - outside the dev window, when the model itself is limited in dev
     returns  = expected keys absent from staging

   One direction only: staging may hold MORE keys than expected (a delete applied by the
   next run's post-hook), never fewer. Composite keys are joined with ':' exactly like the
   delete trigger logs them, e.g. account_holders -> 'account_id:customer_id'.
------------------------------------------------------------------------------------- #}
{% macro missing_from_staging(staging_model, bronze_source, table_name, key_columns, dev_ts=none) -%}
    {%- set bronze_parts = [] -%}
    {%- set staging_parts = [] -%}
    {%- for column in key_columns -%}
        {%- do bronze_parts.append("record:" ~ column ~ "::string") -%}
        {%- do staging_parts.append(column ~ "::string") -%}
    {%- endfor -%}
    {%- set separator = " || ':' || " -%}

    select '{{ table_name }}' as table_name, expected.key_value as missing_key
    from (
        select distinct {{ bronze_parts | join(separator) }} as key_value
        from {{ bronze_source }}
        where _extracted_at <= (select max(_extracted_at) from {{ staging_model }})
        {%- if dev_ts %}
        {{ limit_in_dev(dev_ts) }}
        {%- endif %}
    ) expected
    where not exists (
            select 1 from {{ ref('stg_postgres__deleted_records') }} d
            where d.table_name = '{{ table_name }}' and d.pk_value = expected.key_value
        )
      and not exists (
            select 1 from {{ staging_model }} s
            where {{ staging_parts | join(separator) }} = expected.key_value
        )
{%- endmacro %}
