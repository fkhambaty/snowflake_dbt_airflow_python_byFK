{#
  Governance as model metadata.

  A model declares what protects it:

      {{ config(meta={'governance': {
          'row_access': {'policy': 'RAP_CUSTOMER_SCOPE', 'column': 'customer_id'},
          'pii': {'email': 'contact', 'phone': 'contact'}
      }}) }}

  apply_governance() runs as a post-hook in prod. A table rebuild (CREATE OR REPLACE)
  drops policies and tags, so they are put back on every build.

  The policies themselves are owned by security (03_snowflake/06_row_level_security.sql),
  not by dbt. dbt only APPLIES them. Until that script has run, this macro logs a warning
  and does nothing, so the very first build still succeeds.

  Masking is tag-based: the masking policy is attached to the tag GOVERNANCE.PII, and dbt
  only sets the tag on the column. SET TAG is idempotent, and a new PII column needs one
  line of metadata, not a new ALTER ... SET MASKING POLICY.
#}

{% macro governance_installed() %}
    {% set found = run_query(
        "show row access policies like 'RAP_CUSTOMER_SCOPE' in database " ~ target.database
    ) %}
    {{ return(found is not none and (found.rows | length) > 0) }}
{% endmacro %}


{% macro _govern_relation(relation, governance) %}
    {% set gov_schema = target.database ~ '.GOVERNANCE' %}
    {% set row_access = governance.get('row_access') %}
    {% if row_access %}
        {% do run_query('alter table ' ~ relation ~ ' drop all row access policies') %}
        {% do run_query(
            'alter table ' ~ relation ~ ' add row access policy ' ~ gov_schema ~ '.' ~ row_access['policy']
            ~ ' on (' ~ row_access['column'] ~ ')'
        ) %}
    {% endif %}
    {% for column, kind in governance.get('pii', {}).items() %}
        {% do run_query(
            'alter table ' ~ relation ~ ' modify column ' ~ column
            ~ ' set tag ' ~ gov_schema ~ ".PII = '" ~ kind ~ "'"
        ) %}
    {% endfor %}
    {{ log('governance applied to ' ~ relation, info=True) }}
{% endmacro %}


{% macro apply_governance() %}
    {% if execute and target.name == 'prod' and model.config.materialized in ['table', 'incremental'] %}
        {% set governance = config.get('meta', {}).get('governance', {}) %}
        {% if governance %}
            {% if governance_installed() %}
                {% do _govern_relation(this, governance) %}
            {% else %}
                {{ log('WARNING: ' ~ this ~ ' declares governance but 06_row_level_security.sql has not run. Built without row policy.', info=True) }}
            {% endif %}
        {% endif %}
    {% endif %}
    select 1
{% endmacro %}


{#  dbt run-operation apply_governance_all --target prod
    Attach every declared policy without rebuilding. Run once after 06_row_level_security.sql. #}
{% macro apply_governance_all() %}
    {% if not governance_installed() %}
        {{ exceptions.raise_compiler_error('Run 03_snowflake/06_row_level_security.sql first.') }}
    {% endif %}
    {% for node in graph.nodes.values()
        if node.resource_type == 'model'
        and node.config.materialized in ['table', 'incremental']
        and node.config.get('meta', {}).get('governance') %}
        {% set relation = adapter.get_relation(node.database, node.schema, node.alias) %}
        {% if relation is none %}
            {{ log('skipped ' ~ node.name ~ ': not built in ' ~ target.name, info=True) }}
        {% else %}
            {% do _govern_relation(relation, node.config.meta.governance) %}
        {% endif %}
    {% endfor %}
{% endmacro %}
