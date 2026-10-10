-- =====================================================================================
--  Change Data Capture helpers
--
--  Our ingestion is "watermark CDC": SELECT ... WHERE updated_at > :last_watermark.
--  For that to be trustworthy TWO things must be guaranteed by the source:
--    1. updated_at is ALWAYS bumped on UPDATE  -> BEFORE UPDATE trigger (apps forget!)
--    2. hard DELETEs are recorded somewhere    -> AFTER DELETE trigger into cdc.deleted_records
--
--  Production alternative (talk about it in the video): logical replication / Debezium reading
--  the WAL. wal_level=logical is already enabled in docker-compose; see bottom of this file.
-- =====================================================================================
-- Execute the whole script in DBeaver, connected to meridian_core.

CREATE OR REPLACE FUNCTION cdc.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := clock_timestamp();   -- clock_timestamp(), not now(): now() is frozen per transaction
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION cdc.log_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_pk text;
BEGIN
  -- TG_ARGV[0] carries the PK column name so one function serves every table
  EXECUTE format('SELECT ($1).%I::text', TG_ARGV[0]) INTO v_pk USING OLD;
  INSERT INTO cdc.deleted_records (schema_name, table_name, pk_value, deleted_at)
  VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, v_pk, clock_timestamp());
  RETURN OLD;
END $$;

-- Attach to every tracked table -----------------------------------------------------------
DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT * FROM (VALUES
      ('ref','currencies','currency_code'),
      ('ref','countries','country_code'),
      ('ref','fx_rates','fx_rate_id'),
      ('ref','channels','channel_id'),
      ('ref','products','product_id'),
      ('core','branches','branch_id'),
      ('core','employees','employee_id'),
      ('core','customers','customer_id'),
      ('core','accounts','account_id'),
      ('core','transactions','transaction_id'),
      ('core','loan_applications','application_id'),
      ('core','customer_features','customer_id'),
      ('core','card_applications','application_id'),
      ('core','credit_cards','card_id'),
      ('core','card_authorizations','authorization_id'),
      ('ref','merchants','merchant_id'),
      ('ref','sale_events','sale_event_id'),
      ('ref','offer_catalog','offer_code')
    ) AS v(schema_name, table_name, pk_col)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_updated_at ON %I.%I', t.schema_name, t.table_name);
    EXECUTE format('CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON %I.%I
                    FOR EACH ROW EXECUTE FUNCTION cdc.set_updated_at()', t.schema_name, t.table_name);

    EXECUTE format('DROP TRIGGER IF EXISTS trg_log_delete ON %I.%I', t.schema_name, t.table_name);
    EXECUTE format('CREATE TRIGGER trg_log_delete AFTER DELETE ON %I.%I
                    FOR EACH ROW EXECUTE FUNCTION cdc.log_delete(%L)', t.schema_name, t.table_name, t.pk_col);
  END LOOP;
END $$;

-- account_holders has a composite PK; log it as "account_id:customer_id"
CREATE OR REPLACE FUNCTION cdc.log_delete_account_holder() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO cdc.deleted_records (schema_name, table_name, pk_value)
  VALUES ('core', 'account_holders', OLD.account_id || ':' || OLD.customer_id);
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS trg_set_updated_at ON core.account_holders;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON core.account_holders FOR EACH ROW EXECUTE FUNCTION cdc.set_updated_at();
DROP TRIGGER IF EXISTS trg_log_delete ON core.account_holders;
CREATE TRIGGER trg_log_delete AFTER DELETE ON core.account_holders FOR EACH ROW EXECUTE FUNCTION cdc.log_delete_account_holder();

-- ------------------------------------------------------------------------------------------
-- OPTIONAL: logical replication publication (for a Debezium / Snowflake Openflow demo).
-- REPLICA IDENTITY FULL makes the WAL carry the whole old row on UPDATE/DELETE.
-- ------------------------------------------------------------------------------------------
-- ALTER TABLE core.transactions REPLICA IDENTITY FULL;
-- CREATE PUBLICATION meridian_pub FOR TABLES IN SCHEMA core, ref;
-- SELECT * FROM pg_create_logical_replication_slot('meridian_slot', 'pgoutput');

-- Smoke test ---------------------------------------------------------------------------------
-- UPDATE core.customers SET segment = 'PREMIUM' WHERE customer_id = 1;  SELECT updated_at FROM core.customers WHERE customer_id = 1;
-- DELETE FROM core.transactions WHERE transaction_id = (SELECT max(transaction_id) FROM core.transactions);
-- SELECT * FROM cdc.deleted_records ORDER BY deleted_at DESC LIMIT 5;
