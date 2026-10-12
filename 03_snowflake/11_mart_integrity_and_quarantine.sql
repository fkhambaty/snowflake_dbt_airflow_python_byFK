-- =====================================================================================
--  Mart integrity and quarantine.
--  Run as MERIDIAN_TRANSFORMER after `dbt build --target prod`.
--  meridian_daily_batch runs this file after dbt build and before reconciliation.
--  A MART / VIOLATION row raises. The Airflow task fails. Reconcile does not run.
--
--  Snowflake constraints
--    PRIMARY KEY and FOREIGN KEY are informational. Snowflake stores them, and RELY
--    may let the optimizer assume them, but a duplicate key and an orphan row both
--    insert successfully. UNIQUE is informational in the same way.
--    NOT NULL is enforced. An INSERT of NULL into a NOT NULL column fails.
--    dbt tests (unique, not_null, relationships) and this script are the controls
--    that actually reject bad marts. A constraint name in the catalog is not.
--
--  Two responses when a fact's dimension member is missing
--    Unknown member: keep the fact in the mart and point the surrogate at '-1'
--    (the row dim_* already carries). Totals stay complete. The gap stays visible.
--    Quarantine: copy the fact into INTEGRITY.MART_QUARANTINE and record the key
--    and the reason. Use this when the key is neither a real member nor '-1'.
--    This script does not delete from MARTS. Repair is a reviewed dbt rebuild.
--
--  DEMO scope is the lesson (it must show a duplicate, an orphan, and an accepted
--  unknown member). MART scope is production. Only MART + VIOLATION fails the run.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;
USE DATABASE MERIDIAN_ANALYTICS;

CREATE SCHEMA IF NOT EXISTS MERIDIAN_ANALYTICS.INTEGRITY
  COMMENT = 'Current mart defects and quarantined payloads. Owned by the transformer role.';

SET integrity_run_id = (SELECT UUID_STRING());

CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    exception_id    STRING DEFAULT UUID_STRING(),
    run_id          STRING NOT NULL,
    detected_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    check_scope     STRING NOT NULL,   -- DEMO lesson, or MART production
    severity        STRING NOT NULL,   -- VIOLATION fails the daily DAG. ACCEPTED does not.
    violation_type  STRING NOT NULL,
    source_object   STRING NOT NULL,
    business_key    STRING NOT NULL,
    reason          STRING NOT NULL,
    action_hint     STRING NOT NULL
);

CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE (
    quarantine_id   STRING DEFAULT UUID_STRING(),
    run_id          STRING NOT NULL,
    detected_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    check_scope     STRING NOT NULL,
    source_object   STRING NOT NULL,
    business_key    STRING NOT NULL,
    violation_type  STRING NOT NULL,
    reason          STRING NOT NULL,
    disposition     STRING NOT NULL,   -- QUARANTINED. Unknown-member rows are not copied here.
    action_hint     STRING NOT NULL,
    payload         VARIANT
);

CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON (
    lesson    STRING NOT NULL,
    observed  STRING NOT NULL
);

-- ------------------------------------------------------------------ informational keys vs NOT NULL
-- The primary key and the foreign key below are declared on purpose. The duplicate
-- insert and the orphan insert both succeed. RELY is not used: RELY does not enforce.
CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.INTEGRITY.DEMO_DIM_ACCOUNT (
    account_key STRING NOT NULL,
    account_id  NUMBER,
    CONSTRAINT pk_demo_dim_account PRIMARY KEY (account_key) NOT ENFORCED
);

CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT (
    transaction_id NUMBER NOT NULL,
    account_key    STRING,
    amount         NUMBER(18, 2),
    CONSTRAINT pk_demo_fct PRIMARY KEY (transaction_id) NOT ENFORCED,
    CONSTRAINT fk_demo_fct_account FOREIGN KEY (account_key)
        REFERENCES MERIDIAN_ANALYTICS.INTEGRITY.DEMO_DIM_ACCOUNT (account_key) NOT ENFORCED
);

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.DEMO_DIM_ACCOUNT (account_key, account_id) VALUES
    ('A-100', 100),
    ('-1', -1);

-- transaction_id 2 is inserted twice (duplicate business key).
-- transaction_id 3 points at NO-SUCH (orphan). The foreign key does not reject it.
-- transaction_id 4 points at -1 (unknown member). That row stays out of quarantine.
INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT (transaction_id, account_key, amount) VALUES
    (1, 'A-100', 10),
    (2, 'A-100', 12),
    (2, 'A-100', 12),
    (3, 'NO-SUCH', 99),
    (4, '-1', 5);

CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.INTEGRITY.NULL_DEMO (
    id   NUMBER NOT NULL,
    note STRING
);

-- NOT NULL is enforced. The failed insert is caught so this script can continue,
-- and the lesson row records the error Snowflake raised.
EXECUTE IMMEDIATE $$
BEGIN
    INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.NULL_DEMO (id, note)
    VALUES (NULL, 'should fail');
    INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON (lesson, observed)
    VALUES ('NOT NULL', 'NOT ENFORCED');
EXCEPTION
    WHEN OTHER THEN
        INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON (lesson, observed)
        VALUES ('NOT NULL', 'enforced: ' || SQLERRM);
END;
$$;

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON (lesson, observed)
SELECT 'PRIMARY KEY', 'informational: duplicate transaction_id 2 inserted ' || COUNT(*) || ' times'
FROM MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT
WHERE transaction_id = 2;

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON (lesson, observed)
SELECT 'FOREIGN KEY', 'informational: orphan account_key ' || account_key || ' inserted'
FROM MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT
WHERE transaction_id = 3;

-- ------------------------------------------------------------------ DEMO: write the lesson
INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'DEMO',
    'VIOLATION',
    'DUPLICATE_BUSINESS_KEY',
    'INTEGRITY.DEMO_FCT',
    transaction_id::STRING,
    'transaction_id appears ' || COUNT(*) || ' times. The PRIMARY KEY was declared and did not reject the insert.',
    'Keep one surviving row. Adding a Snowflake primary key will not stop the next duplicate.'
FROM MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT
GROUP BY transaction_id
HAVING COUNT(*) > 1;

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'DEMO',
    'VIOLATION',
    'ORPHAN_FACT',
    'INTEGRITY.DEMO_FCT',
    f.transaction_id::STRING,
    'account_key ' || COALESCE(f.account_key, 'NULL') || ' is not in DEMO_DIM_ACCOUNT and is not the unknown member -1.',
    'Quarantine this fact. The other choice is the unknown member, and this key is not that member.'
FROM MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT f
LEFT JOIN MERIDIAN_ANALYTICS.INTEGRITY.DEMO_DIM_ACCOUNT d
    ON d.account_key = f.account_key
WHERE d.account_key IS NULL
  AND COALESCE(f.account_key, '') <> '-1';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'DEMO',
    'ACCEPTED',
    'UNKNOWN_MEMBER',
    'INTEGRITY.DEMO_FCT',
    transaction_id::STRING,
    'account_key -1 is the unknown member. The fact stays in the mart so the amount is not lost.',
    'Do not quarantine. Repair the source key when the real member is known.'
FROM MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT
WHERE account_key = '-1';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE (
    run_id, check_scope, source_object, business_key, violation_type, reason, disposition, action_hint, payload
)
SELECT
    e.run_id,
    e.check_scope,
    e.source_object,
    e.business_key,
    e.violation_type,
    e.reason,
    'QUARANTINED',
    e.action_hint,
    OBJECT_CONSTRUCT(
        'transaction_id', f.transaction_id,
        'account_key', f.account_key,
        'amount', f.amount
    )
FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION e
JOIN MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT f
    ON f.transaction_id::STRING = e.business_key
WHERE e.run_id = $integrity_run_id
  AND e.check_scope = 'DEMO'
  AND e.severity = 'VIOLATION';

-- The lesson is wrong if the duplicate was collapsed, the orphan was not held,
-- the unknown member was quarantined, or NOT NULL let a NULL through.
EXECUTE IMMEDIATE $$
DECLARE
    duplicate_rows INTEGER;
    orphan_held INTEGER;
    unknown_held INTEGER;
    not_null_enforced INTEGER;
BEGIN
    SELECT COUNT(*) INTO :duplicate_rows
    FROM MERIDIAN_ANALYTICS.INTEGRITY.DEMO_FCT
    WHERE transaction_id = 2;

    SELECT COUNT(*) INTO :orphan_held
    FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE
    WHERE check_scope = 'DEMO'
      AND business_key = '3'
      AND violation_type = 'ORPHAN_FACT';

    SELECT COUNT(*) INTO :unknown_held
    FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE
    WHERE check_scope = 'DEMO'
      AND business_key = '4';

    SELECT COUNT(*) INTO :not_null_enforced
    FROM MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON
    WHERE lesson = 'NOT NULL'
      AND observed ILIKE 'enforced:%';

    IF (duplicate_rows <> 2 OR orphan_held <> 1 OR unknown_held <> 0 OR not_null_enforced <> 1) THEN
        RAISE STATEMENT_ERROR(-20002, 'integrity lesson failed: primary/foreign key informational, NOT NULL enforced, unknown member kept');
    END IF;
    RETURN 'integrity lesson ok';
END;
$$;

SELECT lesson, observed
FROM MERIDIAN_ANALYTICS.INTEGRITY.CONSTRAINT_LESSON
ORDER BY lesson;

SELECT check_scope, severity, violation_type, business_key, reason
FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION
WHERE check_scope = 'DEMO'
ORDER BY severity, business_key;

-- ------------------------------------------------------------------ MART: duplicate business keys
-- transaction_id is the fact grain. branch_id is the branch grain.
-- customer_id alone is not a grain: SCD2 keeps many versions. The business key
-- of a version is (customer_id, valid_from).
INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'DUPLICATE_BUSINESS_KEY',
    'MARTS.FCT_TRANSACTIONS',
    transaction_id::STRING,
    'transaction_id appears ' || COUNT(*) || ' times. A Snowflake PRIMARY KEY would not have stopped this.',
    'Identify the surviving row, then rebuild fct_transactions. Do not expect a primary key to reject the next load.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS
GROUP BY transaction_id
HAVING COUNT(*) > 1;

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'DUPLICATE_BUSINESS_KEY',
    'MARTS.DIM_BRANCH',
    branch_id::STRING,
    'branch_id appears ' || COUNT(*) || ' times.',
    'Keep one row per branch_id and rebuild dim_branch.'
FROM MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH
GROUP BY branch_id
HAVING COUNT(*) > 1;

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'DUPLICATE_BUSINESS_KEY',
    'MARTS.DIM_CUSTOMER',
    customer_id::STRING || '|' || TO_VARCHAR(valid_from, 'YYYY-MM-DD HH24:MI:SS.FF3'),
    'customer_id ' || customer_id::STRING || ' has ' || COUNT(*) || ' rows for the same valid_from.',
    'SCD2 allows many versions. It does not allow two rows for the same version. Rebuild dim_customer.'
FROM MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER
WHERE customer_id <> -1
GROUP BY customer_id, valid_from
HAVING COUNT(*) > 1;

-- ------------------------------------------------------------------ MART: orphan facts
-- A key of '-1' is the unknown member, not an orphan, when that member exists.
-- A key of '-1' when the member is missing is UNKNOWN_MEMBER_MISSING.
-- Any other missing key is ORPHAN_FACT and is copied to quarantine.
INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'ORPHAN_FACT',
    'MARTS.FCT_TRANSACTIONS',
    f.transaction_id::STRING,
    'account_key ' || COALESCE(f.account_key, 'NULL') || ' is not in dim_account and is not the unknown member -1.',
    'Load the missing account, or point the fact at the unknown member and rebuild. This key was quarantined.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
LEFT JOIN MERIDIAN_ANALYTICS.MARTS.DIM_ACCOUNT d
    ON d.account_key = f.account_key
WHERE d.account_key IS NULL
  AND COALESCE(f.account_key, '') <> '-1';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'ORPHAN_FACT',
    'MARTS.FCT_TRANSACTIONS',
    f.transaction_id::STRING,
    'customer_key ' || COALESCE(f.customer_key, 'NULL') || ' is not in dim_customer and is not the unknown member -1.',
    'Load the missing customer version, or point the fact at the unknown member and rebuild.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
LEFT JOIN MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER d
    ON d.customer_key = f.customer_key
WHERE d.customer_key IS NULL
  AND COALESCE(f.customer_key, '') <> '-1';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'ORPHAN_FACT',
    'MARTS.FCT_TRANSACTIONS',
    f.transaction_id::STRING,
    'branch_key ' || COALESCE(f.branch_key, 'NULL') || ' is not in dim_branch and is not the unknown member -1.',
    'Load the missing branch, or point the fact at the unknown member and rebuild.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
LEFT JOIN MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH d
    ON d.branch_key = f.branch_key
WHERE d.branch_key IS NULL
  AND COALESCE(f.branch_key, '') <> '-1';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'UNKNOWN_MEMBER_MISSING',
    'MARTS.FCT_TRANSACTIONS',
    f.transaction_id::STRING,
    'account_key is the unknown member -1 but dim_account has no such row.',
    'Rebuild dim_account so the unknown member exists, or quarantine these facts. The unknown-member choice is only valid when -1 is in the dimension.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
WHERE f.account_key = '-1'
  AND NOT EXISTS (
      SELECT 1 FROM MERIDIAN_ANALYTICS.MARTS.DIM_ACCOUNT d WHERE d.account_key = '-1'
  );

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'UNKNOWN_MEMBER_MISSING',
    'MARTS.FCT_TRANSACTIONS',
    f.transaction_id::STRING,
    'customer_key is the unknown member -1 but dim_customer has no such row.',
    'Rebuild dim_customer so the unknown member exists.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
WHERE f.customer_key = '-1'
  AND NOT EXISTS (
      SELECT 1 FROM MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER d WHERE d.customer_key = '-1'
  );

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'VIOLATION',
    'UNKNOWN_MEMBER_MISSING',
    'MARTS.FCT_TRANSACTIONS',
    f.transaction_id::STRING,
    'branch_key is the unknown member -1 but dim_branch has no such row.',
    'Rebuild dim_branch so the unknown member exists.'
FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
WHERE f.branch_key = '-1'
  AND NOT EXISTS (
      SELECT 1 FROM MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH d WHERE d.branch_key = '-1'
  );

-- Accepted on purpose: the fact remains in the mart. One summary row, not one row per fact.
INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION (
    run_id, check_scope, severity, violation_type, source_object, business_key, reason, action_hint
)
SELECT
    $integrity_run_id,
    'MART',
    'ACCEPTED',
    'UNKNOWN_MEMBER',
    'MARTS.FCT_TRANSACTIONS',
    '-1',
    s.n || ' facts stay on the unknown account member. They are not orphans.',
    'Quarantine would drop the amount. The unknown member keeps the fact. Investigate the source key. Do not delete the fact.'
FROM (
    SELECT COUNT(*) AS n
    FROM MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS
    WHERE account_key = '-1'
) s
WHERE s.n > 0
  AND EXISTS (
      SELECT 1 FROM MERIDIAN_ANALYTICS.MARTS.DIM_ACCOUNT d WHERE d.account_key = '-1'
  );

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE (
    run_id, check_scope, source_object, business_key, violation_type, reason, disposition, action_hint, payload
)
SELECT
    e.run_id,
    e.check_scope,
    e.source_object,
    e.business_key,
    e.violation_type,
    e.reason,
    'QUARANTINED',
    e.action_hint,
    OBJECT_CONSTRUCT(
        'transaction_id', f.transaction_id,
        'account_key', f.account_key,
        'customer_key', f.customer_key,
        'branch_key', f.branch_key,
        'amount_reporting', f.amount_reporting
    )
FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION e
JOIN MERIDIAN_ANALYTICS.MARTS.FCT_TRANSACTIONS f
    ON f.transaction_id::STRING = e.business_key
WHERE e.run_id = $integrity_run_id
  AND e.check_scope = 'MART'
  AND e.severity = 'VIOLATION'
  AND e.source_object = 'MARTS.FCT_TRANSACTIONS';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE (
    run_id, check_scope, source_object, business_key, violation_type, reason, disposition, action_hint, payload
)
SELECT
    e.run_id,
    e.check_scope,
    e.source_object,
    e.business_key,
    e.violation_type,
    e.reason,
    'QUARANTINED',
    e.action_hint,
    OBJECT_CONSTRUCT('branch_id', b.branch_id, 'branch_key', b.branch_key, 'branch_code', b.branch_code)
FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION e
JOIN MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH b
    ON b.branch_id::STRING = e.business_key
WHERE e.run_id = $integrity_run_id
  AND e.check_scope = 'MART'
  AND e.severity = 'VIOLATION'
  AND e.source_object = 'MARTS.DIM_BRANCH';

INSERT INTO MERIDIAN_ANALYTICS.INTEGRITY.MART_QUARANTINE (
    run_id, check_scope, source_object, business_key, violation_type, reason, disposition, action_hint, payload
)
SELECT
    e.run_id,
    e.check_scope,
    e.source_object,
    e.business_key,
    e.violation_type,
    e.reason,
    'QUARANTINED',
    e.action_hint,
    OBJECT_CONSTRUCT('customer_id', c.customer_id, 'customer_key', c.customer_key, 'valid_from', c.valid_from)
FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION e
JOIN MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER c
    ON c.customer_id::STRING || '|' || TO_VARCHAR(c.valid_from, 'YYYY-MM-DD HH24:MI:SS.FF3') = e.business_key
WHERE e.run_id = $integrity_run_id
  AND e.check_scope = 'MART'
  AND e.severity = 'VIOLATION'
  AND e.source_object = 'MARTS.DIM_CUSTOMER';

-- ------------------------------------------------------------------ revoke direct writes on marts
-- dbt, as MERIDIAN_TRANSFORMER, owns the tables and remains the only writer.
-- Consumer and ingestion roles keep SELECT through dbt grants. They lose INSERT,
-- UPDATE, DELETE and TRUNCATE so a worksheet cannot corrupt a mart between builds.
-- Revoking a privilege that was never granted is a no-op.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_LOADER;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_ANALYST;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_ML;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_APP;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_CEO;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_BRANCH_MANAGER;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_STAFF;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_CUSTOMER;

-- A future grant may not exist yet. A missing future grant is ignored.
-- Insufficient privileges are not ignored.
EXECUTE IMMEDIATE $$
BEGIN
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_LOADER;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_ANALYST;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_ML;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_APP;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_CEO;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_BRANCH_MANAGER;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_STAFF;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    BEGIN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.MARTS FROM ROLE MERIDIAN_CUSTOMER;
    EXCEPTION WHEN OTHER THEN
        IF (POSITION('does not exist', LOWER(SQLERRM)) = 0
            AND POSITION('not granted', LOWER(SQLERRM)) = 0
            AND POSITION('future grant', LOWER(SQLERRM)) = 0) THEN
            RAISE;
        END IF;
    END;
    RETURN 'future write grants on marts cleared where they existed';
END;
$$;

GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.INTEGRITY TO ROLE MERIDIAN_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.INTEGRITY TO ROLE MERIDIAN_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MERIDIAN_ANALYTICS.INTEGRITY TO ROLE MERIDIAN_ANALYST;

-- Analysts can read the defect list. They still cannot write the marts or this schema's tables.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA MERIDIAN_ANALYTICS.INTEGRITY FROM ROLE MERIDIAN_ANALYST;

-- ------------------------------------------------------------------ fail the daily run
-- Inserts above are already committed. This block only reads and raises, so the
-- orphan's key and reason remain in MART_INTEGRITY_EXCEPTION when the task fails.
EXECUTE IMMEDIATE $$
DECLARE
    violation_count INTEGER;
    violation_sample STRING;
BEGIN
    SELECT COUNT(*) INTO :violation_count
    FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION
    WHERE check_scope = 'MART'
      AND severity = 'VIOLATION';

    IF (violation_count > 0) THEN
        SELECT LEFT(
                   LISTAGG(source_object || ' key=' || business_key || ' ' || reason, ' || ')
                       WITHIN GROUP (ORDER BY source_object, business_key),
                   900
               )
          INTO :violation_sample
        FROM (
            SELECT source_object, business_key, reason
            FROM MERIDIAN_ANALYTICS.INTEGRITY.MART_INTEGRITY_EXCEPTION
            WHERE check_scope = 'MART'
              AND severity = 'VIOLATION'
            QUALIFY ROW_NUMBER() OVER (ORDER BY source_object, business_key) <= 15
        );

        RAISE STATEMENT_ERROR(
            -20001,
            'mart integrity violations=' || violation_count || ' ' || COALESCE(violation_sample, '')
        );
    END IF;
    RETURN 'mart integrity ok';
END;
$$;
