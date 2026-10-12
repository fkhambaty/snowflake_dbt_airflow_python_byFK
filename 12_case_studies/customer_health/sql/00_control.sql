-- AcmeCloud customer-health case. Every seed row is labelled SYNTHETIC.
-- Grain of the published mart: one row per salesforce_account_id per snapshot_date.
-- Identity is the Salesforce account id plus the source crosswalk. Display name is an attribute.

CREATE TABLE pipeline_run (
    snapshot_date DATE,
    as_of_timestamp TIMESTAMP,
    business_timezone VARCHAR,
    health_score_version VARCHAR
);

-- Local wall-clock bounds. AT TIME ZONE in later views converts these to UTC instants.
-- Activity is 30 inclusive local days: [snapshot_date - 29 days, snapshot_date].
-- Support and CSAT are 90 inclusive local days: [snapshot_date - 89 days, snapshot_date].
CREATE VIEW run_params AS
SELECT
    snapshot_date,
    as_of_timestamp,
    business_timezone,
    health_score_version,
    CAST(snapshot_date AS TIMESTAMP) - INTERVAL 29 DAY AS activity_start_local,
    CAST(snapshot_date AS TIMESTAMP) - INTERVAL 89 DAY AS lookback_90_start_local,
    CAST(snapshot_date AS TIMESTAMP) + INTERVAL 1 DAY AS window_end_local
FROM pipeline_run;
