-- =====================================================================================
--  FinOps and operational evidence. Run as ACCOUNTADMIN after 01-03 and governance.
--  ACCOUNT_USAGE normally lags by up to ~3 hours; these are trend/reporting views, not alerts.
--
--  Snowflake meters compute at warehouse level. Per-query credits below are an ESTIMATE:
--  allocate each warehouse/day's credits by query execution milliseconds. State that caveat.
-- =====================================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_BI_XS;

CREATE SCHEMA IF NOT EXISTS MERIDIAN_ANALYTICS.OPERATIONS
  COMMENT = 'Read-only operating evidence: spend, query attribution, freshness and failures.';

CREATE OR REPLACE SECURE VIEW MERIDIAN_ANALYTICS.OPERATIONS.V_WAREHOUSE_CREDITS_DAILY AS
SELECT
    usage_date,
    warehouse_name,
    round(sum(credits_used_compute), 3)         AS compute_credits,
    round(sum(credits_used_cloud_services), 3)  AS cloud_services_credits,
    round(sum(credits_used), 3)                 AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= dateadd('day', -90, current_timestamp())
  AND warehouse_name LIKE 'WH_%'
GROUP BY 1, 2;

CREATE OR REPLACE SECURE VIEW MERIDIAN_ANALYTICS.OPERATIONS.V_QUERY_COST_ATTRIBUTION AS
WITH queries AS (
    SELECT
        query_id,
        to_date(start_time) AS usage_date,
        warehouse_name,
        user_name,
        role_name,
        coalesce(nullif(query_tag, ''), 'UNTAGGED') AS workload,
        regexp_substr(query_text, 'node=([^*| ]+)', 1, 1, 'e', 1) AS dbt_node,
        execution_time,
        total_elapsed_time,
        bytes_scanned,
        rows_produced,
        error_code,
        error_message
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= dateadd('day', -90, current_timestamp())
      AND warehouse_name LIKE 'WH_%'
),
day_totals AS (
    SELECT usage_date, warehouse_name, sum(execution_time) AS warehouse_execution_ms
    FROM queries
    GROUP BY 1, 2
)
SELECT
    q.*,
    round(
        c.compute_credits * q.execution_time / nullif(d.warehouse_execution_ms, 0),
        6
    ) AS estimated_compute_credits
FROM queries q
JOIN day_totals d USING (usage_date, warehouse_name)
JOIN MERIDIAN_ANALYTICS.OPERATIONS.V_WAREHOUSE_CREDITS_DAILY c
  USING (usage_date, warehouse_name);

CREATE OR REPLACE SECURE VIEW MERIDIAN_ANALYTICS.OPERATIONS.V_PLATFORM_STATUS AS
SELECT
    'HOT_SOURCE' AS signal_type,
    table_name AS signal_name,
    iff(minutes_behind_source <= 15 AND last_status IN ('SUCCESS', 'NO_CHANGES'), 'PASS', 'FAIL') AS status,
    minutes_behind_source::float AS value,
    'minutes behind (target <= 15)' AS unit,
    last_finished_at AS observed_at
FROM MERIDIAN_RAW.CONTROL.V_PIPELINE_HEALTH
WHERE table_name IN ('core.transactions', 'core.card_applications',
                     'core.card_authorizations', 'cdc.deleted_records')
UNION ALL
SELECT
    'RECONCILIATION',
    grouped_by,
    status,
    mismatch_groups::float,
    'mismatched groups (target = 0)',
    checked_at
FROM MERIDIAN_RAW.CONTROL.V_RECONCILIATION_STATUS;

GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.OPERATIONS TO ROLE MERIDIAN_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA MERIDIAN_ANALYTICS.OPERATIONS TO ROLE MERIDIAN_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA MERIDIAN_ANALYTICS.OPERATIONS TO ROLE MERIDIAN_TRANSFORMER;

-- Interview/demo queries ---------------------------------------------------------------
SELECT * FROM MERIDIAN_ANALYTICS.OPERATIONS.V_PLATFORM_STATUS ORDER BY status, signal_type;

SELECT workload, dbt_node,
       count(*) AS queries,
       round(sum(estimated_compute_credits), 3) AS estimated_credits,
       round(sum(bytes_scanned) / power(1024, 3), 2) AS gb_scanned
FROM MERIDIAN_ANALYTICS.OPERATIONS.V_QUERY_COST_ATTRIBUTION
WHERE usage_date >= dateadd('day', -7, current_date())
GROUP BY 1, 2
ORDER BY estimated_credits DESC NULLS LAST;
