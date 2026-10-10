-- =====================================================================================
--  Snowflake-native near-real-time: Streams + Tasks, and Dynamic Tables
--  (Episode 3). This is the "what if we did NOT use dbt for the hot path?" demo and the
--  answer to the interview question "how would you get 1-minute latency in Snowflake?"
--
--  Pattern A  Stream (CDC on the raw table) + Task (scheduled MERGE) -> ODS current-state table
--  Pattern B  Dynamic Table with TARGET_LAG -> declarative, Snowflake decides when to refresh
--
--  Our course keeps dbt as the source of truth for modelling; these objects live in a
--  separate schema so they never collide with dbt-managed tables.
-- =====================================================================================
USE ROLE MERIDIAN_LOADER;
USE WAREHOUSE WH_INGEST_XS;
CREATE SCHEMA IF NOT EXISTS MERIDIAN_RAW.ODS COMMENT = 'Operational data store: current state via Streams/Tasks and Dynamic Tables (demo)';

-- ------------------------------------------------------------------ Pattern A: Stream + Task
-- A stream is a bookmark on a table's change log. Reading it inside a DML advances the bookmark.
CREATE OR REPLACE STREAM MERIDIAN_RAW.ODS.STR_RAW_TRANSACTIONS
  ON TABLE MERIDIAN_RAW.POSTGRES_CORE.TRANSACTIONS
  APPEND_ONLY = TRUE;        -- raw is insert-only, so an append-only stream is cheaper

CREATE TABLE IF NOT EXISTS MERIDIAN_RAW.ODS.TRANSACTIONS_CURRENT (
    transaction_id    NUMBER         PRIMARY KEY,
    account_id        NUMBER,
    transaction_ts    TIMESTAMP_NTZ,
    transaction_type  STRING,
    amount            NUMBER(18,2),
    currency_code     STRING,
    channel_id        NUMBER,
    branch_id         NUMBER,
    status            STRING,
    updated_at        TIMESTAMP_NTZ,
    _extracted_at     TIMESTAMP_NTZ
) CLUSTER BY (to_date(transaction_ts));

CREATE OR REPLACE TASK MERIDIAN_RAW.ODS.TSK_MERGE_TRANSACTIONS
  WAREHOUSE = WH_INGEST_XS
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('MERIDIAN_RAW.ODS.STR_RAW_TRANSACTIONS')   -- no data, no warehouse spin-up, no cost
AS
MERGE INTO MERIDIAN_RAW.ODS.TRANSACTIONS_CURRENT t
USING (
    -- several versions of one transaction can arrive in one minute -> keep the latest
    SELECT record:transaction_id::number      AS transaction_id,
           record:account_id::number          AS account_id,
           record:transaction_ts::timestamp_ntz AS transaction_ts,
           record:transaction_type::string    AS transaction_type,
           record:amount::number(18,2)        AS amount,
           record:currency_code::string       AS currency_code,
           record:channel_id::number          AS channel_id,
           record:branch_id::number           AS branch_id,
           record:status::string              AS status,
           record:updated_at::timestamp_ntz   AS updated_at,
           _extracted_at
    FROM MERIDIAN_RAW.ODS.STR_RAW_TRANSACTIONS
    QUALIFY row_number() OVER (PARTITION BY record:transaction_id ORDER BY record:updated_at DESC, _extracted_at DESC) = 1
) s
ON t.transaction_id = s.transaction_id
WHEN MATCHED AND s.updated_at > t.updated_at THEN UPDATE SET
     status = s.status, amount = s.amount, updated_at = s.updated_at, _extracted_at = s._extracted_at
WHEN NOT MATCHED THEN INSERT (transaction_id, account_id, transaction_ts, transaction_type, amount, currency_code,
                              channel_id, branch_id, status, updated_at, _extracted_at)
     VALUES (s.transaction_id, s.account_id, s.transaction_ts, s.transaction_type, s.amount, s.currency_code,
             s.channel_id, s.branch_id, s.status, s.updated_at, s._extracted_at);

-- Tasks are created suspended. EXECUTE TASK privilege is needed to resume (ACCOUNTADMIN grants it):
--   USE ROLE ACCOUNTADMIN; GRANT EXECUTE TASK ON ACCOUNT TO ROLE MERIDIAN_LOADER;
ALTER TASK MERIDIAN_RAW.ODS.TSK_MERGE_TRANSACTIONS RESUME;

-- Watch it work:
-- SELECT SYSTEM$STREAM_HAS_DATA('MERIDIAN_RAW.ODS.STR_RAW_TRANSACTIONS');
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TSK_MERGE_TRANSACTIONS')) ORDER BY scheduled_time DESC LIMIT 10;
-- SELECT count(*), max(updated_at) FROM MERIDIAN_RAW.ODS.TRANSACTIONS_CURRENT;

-- ------------------------------------------------------------------ Pattern B: Dynamic Table
-- Declarative: "keep this result at most 2 minutes stale". Snowflake does incremental refresh
-- when the query shape allows it (it does here) and full refresh when it does not.
CREATE OR REPLACE DYNAMIC TABLE MERIDIAN_RAW.ODS.DT_BRANCH_ACTIVITY_LAST_HOUR
  TARGET_LAG = '2 minutes'
  WAREHOUSE = WH_INGEST_XS
AS
SELECT branch_id,
       currency_code,
       count(*)                                                     AS txn_count,
       sum(iff(transaction_type IN ('DEPOSIT','TRANSFER_IN','SALARY_CREDIT','REFUND','INTEREST'), amount, 0)) AS credits,
       sum(iff(transaction_type IN ('DEPOSIT','TRANSFER_IN','SALARY_CREDIT','REFUND','INTEREST'), 0, amount)) AS debits,
       max(transaction_ts)                                          AS last_txn_ts
FROM MERIDIAN_RAW.ODS.TRANSACTIONS_CURRENT
WHERE status = 'POSTED'
  AND branch_id IS NOT NULL
GROUP BY branch_id, currency_code;

-- SELECT * FROM MERIDIAN_RAW.ODS.DT_BRANCH_ACTIVITY_LAST_HOUR ORDER BY txn_count DESC LIMIT 10;
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY()) ORDER BY refresh_start_time DESC LIMIT 10;

-- ------------------------------------------------------------------ when you are done demoing
-- ALTER TASK MERIDIAN_RAW.ODS.TSK_MERGE_TRANSACTIONS SUSPEND;
-- ALTER DYNAMIC TABLE MERIDIAN_RAW.ODS.DT_BRANCH_ACTIVITY_LAST_HOUR SUSPEND;
