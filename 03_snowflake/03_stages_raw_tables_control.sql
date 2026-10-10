-- =====================================================================================
--  Snowflake bootstrap 3/3 : file format, internal stages, raw VARIANT tables, control tables
--  Run as MERIDIAN_LOADER (owner of MERIDIAN_RAW).
--
--  Why VARIANT raw tables?
--    * Postgres can add a column tomorrow; the COPY never breaks and nothing is dropped.
--    * Every historical version of every row is kept (append-only) -> we can rebuild
--      SCD2 dimensions from scratch and audit "what did the source say at 10:03?".
--    * Typing is a transformation concern -> dbt staging. Single place to fix it.
--  Cost: VARIANT columns are columnarised internally by Snowflake for up to ~16MB rows and
--  simple keys, so pruning/compression still work well. We measure that in the perf lab.
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE WAREHOUSE WH_INGEST_XS;
USE DATABASE MERIDIAN_RAW;

-- ------------------------------------------------------------------ file format
CREATE FILE FORMAT IF NOT EXISTS MERIDIAN_RAW.CONTROL.FF_PARQUET
  TYPE = PARQUET
  USE_LOGICAL_TYPE = TRUE          -- Parquet logical types (DECIMAL, TIMESTAMP) are honoured
  COMMENT = 'Parquet written by the Python extractor';

-- ------------------------------------------------------------------ internal stages (one per target schema)
CREATE STAGE IF NOT EXISTS MERIDIAN_RAW.POSTGRES_CORE.PG_STAGE FILE_FORMAT = MERIDIAN_RAW.CONTROL.FF_PARQUET DIRECTORY = (ENABLE = TRUE);
CREATE STAGE IF NOT EXISTS MERIDIAN_RAW.POSTGRES_REF.PG_STAGE  FILE_FORMAT = MERIDIAN_RAW.CONTROL.FF_PARQUET DIRECTORY = (ENABLE = TRUE);
CREATE STAGE IF NOT EXISTS MERIDIAN_RAW.POSTGRES_CDC.PG_STAGE  FILE_FORMAT = MERIDIAN_RAW.CONTROL.FF_PARQUET DIRECTORY = (ENABLE = TRUE);

-- ------------------------------------------------------------------ raw tables: identical shape everywhere
-- One macro-like pattern repeated; the row's business columns live inside RECORD.
CREATE OR REPLACE PROCEDURE MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE(schema_name STRING, table_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  EXECUTE IMMEDIATE
    'CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.' || :schema_name || '.' || :table_name || ' (
        record         VARIANT        NOT NULL,
        _extracted_at  TIMESTAMP_NTZ  NOT NULL,
        _batch_id      STRING         NOT NULL,
        _source_file   STRING,
        _loaded_at     TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
     ) CHANGE_TRACKING = TRUE
       COMMENT = ''Append-only replica of Postgres ' || lower(:schema_name) || '.' || lower(:table_name) || '. Latest version per PK is resolved in dbt staging.''';
  RETURN 'created ' || :schema_name || '.' || :table_name;
END;
$$;

CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'CURRENCIES');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'COUNTRIES');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'CHANNELS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'PRODUCTS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'MERCHANTS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'SALE_EVENTS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'OFFER_CATALOG');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_REF',  'FX_RATES');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'BRANCHES');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'EMPLOYEES');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'CUSTOMERS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'ACCOUNTS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'ACCOUNT_HOLDERS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'TRANSACTIONS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'LOAN_APPLICATIONS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'CUSTOMER_FEATURES');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'CARD_APPLICATIONS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'CREDIT_CARDS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CORE', 'CARD_AUTHORIZATIONS');
CALL MERIDIAN_RAW.CONTROL.CREATE_RAW_TABLE('POSTGRES_CDC',  'DELETED_RECORDS');

-- The big one benefits from a clustering key on the extraction time: dbt's incremental
-- staging model filters on _extracted_at every 5 minutes -> perfect pruning.
ALTER TABLE MERIDIAN_RAW.POSTGRES_CORE.TRANSACTIONS CLUSTER BY (_extracted_at);

-- ------------------------------------------------------------------ control tables
CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.CONTROL.WATERMARKS (
    table_name      STRING         NOT NULL PRIMARY KEY,   -- 'core.transactions'
    last_watermark  TIMESTAMP_NTZ  NOT NULL,
    last_batch_id   STRING,
    updated_at      TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.CONTROL.LOAD_LOG (
    batch_id        STRING         NOT NULL,
    table_name      STRING         NOT NULL,
    low_watermark   TIMESTAMP_NTZ,
    high_watermark  TIMESTAMP_NTZ,
    rows_extracted  NUMBER,
    files_loaded    NUMBER,
    started_at      TIMESTAMP_NTZ,
    finished_at     TIMESTAMP_NTZ,
    status          STRING,                                -- SUCCESS / NO_CHANGES / FAILED
    error_message   STRING
);

CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.CONTROL.RECONCILIATION_RUNS (
    run_id               STRING         NOT NULL PRIMARY KEY,
    checked_at           TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    days_checked         NUMBER         NOT NULL,
    grouped_by           STRING         NOT NULL,
    groups_checked       NUMBER         NOT NULL,
    mismatch_groups      NUMBER         NOT NULL,
    max_abs_row_diff     NUMBER,
    max_abs_amount_diff  NUMBER(18,2),
    freshness_lag_s      NUMBER,
    status               STRING         NOT NULL,  -- PASSED / FAILED
    details              VARIANT
);

-- Reconciliation runs as the dbt service identity: it can read governed marts and may
-- append evidence here, but it does not own ingestion watermarks or load history.
GRANT INSERT, SELECT ON TABLE MERIDIAN_RAW.CONTROL.RECONCILIATION_RUNS
  TO ROLE MERIDIAN_TRANSFORMER;

CREATE STAGE IF NOT EXISTS MERIDIAN_RAW.CONTROL.DBT_ARTIFACTS
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Promoted production manifest and run artifacts for slim CI.';
GRANT READ, WRITE ON STAGE MERIDIAN_RAW.CONTROL.DBT_ARTIFACTS
  TO ROLE MERIDIAN_TRANSFORMER;

-- ------------------------------------------------------------------ observability views (used in the video!)
CREATE OR REPLACE VIEW MERIDIAN_RAW.CONTROL.V_PIPELINE_HEALTH AS
SELECT w.table_name,
       w.last_watermark,
       timestampdiff('minute', w.last_watermark, current_timestamp())   AS minutes_behind_source,
       l.status                                                           AS last_status,
       l.rows_extracted                                                   AS last_rows,
       l.finished_at                                                      AS last_finished_at,
       timestampdiff('second', l.started_at, l.finished_at)               AS last_duration_s
FROM MERIDIAN_RAW.CONTROL.WATERMARKS w
LEFT JOIN MERIDIAN_RAW.CONTROL.LOAD_LOG l
       ON l.table_name = w.table_name
      AND l.batch_id = w.last_batch_id;

CREATE OR REPLACE VIEW MERIDIAN_RAW.CONTROL.V_LOAD_THROUGHPUT AS
SELECT date_trunc('hour', started_at) AS hour,
       table_name,
       count(*)                       AS batches,
       sum(rows_extracted)            AS rows_loaded,
       round(avg(timestampdiff('second', started_at, finished_at)), 1) AS avg_seconds
FROM MERIDIAN_RAW.CONTROL.LOAD_LOG
WHERE status = 'SUCCESS'
GROUP BY 1, 2;

CREATE OR REPLACE VIEW MERIDIAN_RAW.CONTROL.V_RECONCILIATION_STATUS AS
SELECT *
FROM MERIDIAN_RAW.CONTROL.RECONCILIATION_RUNS
QUALIFY row_number() OVER (PARTITION BY grouped_by ORDER BY checked_at DESC) = 1;

CREATE OR REPLACE VIEW MERIDIAN_RAW.CONTROL.V_FAILED_LOADS_24H AS
SELECT batch_id, table_name, started_at, finished_at, error_message
FROM MERIDIAN_RAW.CONTROL.LOAD_LOG
WHERE status = 'FAILED'
  AND started_at >= dateadd('hour', -24, current_timestamp());

-- ------------------------------------------------------------------ ML landing zone
-- Model output is a second source of the warehouse, owned by the ML job (role MERIDIAN_ML).
-- Append-only like every raw table: a re-train adds a run, it never overwrites history.
-- dbt picks the latest SUCCEEDED run per model (stg_ml__model_scores).
CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.ML COMMENT = 'Model runs and scores written by 09_decisioning_python';

CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.ML.MODEL_RUNS (
    run_id           STRING         NOT NULL PRIMARY KEY,
    model_name       STRING         NOT NULL,     -- card_decision_v1, card_propensity_v1, card_fraud_v1
    entity_type      STRING         NOT NULL,     -- APPLICATION | CUSTOMER | AUTHORIZATION
    trained_at       TIMESTAMP_NTZ  NOT NULL,
    training_rows    NUMBER,
    holdout_rows     NUMBER,
    holdout_auc      FLOAT,
    split_strategy   STRING,                      -- TIME or RANDOM, and the cutoff
    features         ARRAY,
    feature_source   STRING,                      -- the gold table the features came from
    code_version     STRING,                      -- git sha of the training script
    status           STRING         NOT NULL      -- SUCCEEDED | REJECTED (AUC below the gate)
);

CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.ML.MODEL_SCORES (
    run_id       STRING         NOT NULL,
    model_name   STRING         NOT NULL,
    entity_type  STRING         NOT NULL,
    entity_id    NUMBER         NOT NULL,
    score        FLOAT          NOT NULL,
    score_band   STRING         NOT NULL,
    explanation  STRING,
    scored_at    TIMESTAMP_NTZ  NOT NULL
);

GRANT USAGE ON SCHEMA MERIDIAN_RAW.ML TO ROLE MERIDIAN_ML;
GRANT INSERT, SELECT ON TABLE MERIDIAN_RAW.ML.MODEL_RUNS   TO ROLE MERIDIAN_ML;
GRANT INSERT, SELECT ON TABLE MERIDIAN_RAW.ML.MODEL_SCORES TO ROLE MERIDIAN_ML;
GRANT CREATE TEMPORARY TABLE ON SCHEMA MERIDIAN_RAW.ML TO ROLE MERIDIAN_ML;   -- write_pandas stages through a temp object
GRANT CREATE STAGE ON SCHEMA MERIDIAN_RAW.ML TO ROLE MERIDIAN_ML;
GRANT SELECT ON ALL TABLES IN SCHEMA MERIDIAN_RAW.ML TO ROLE MERIDIAN_TRANSFORMER;

-- ------------------------------------------------------------------ try the raw layer
-- After the first Python run:
-- SELECT record:customer_id::number, record:segment::string, _extracted_at FROM MERIDIAN_RAW.POSTGRES_CORE.CUSTOMERS LIMIT 10;
-- SELECT * FROM MERIDIAN_RAW.CONTROL.V_PIPELINE_HEALTH ORDER BY minutes_behind_source DESC;
-- LIST @MERIDIAN_RAW.POSTGRES_CORE.PG_STAGE;      -- should be empty: PURGE = TRUE on COPY
