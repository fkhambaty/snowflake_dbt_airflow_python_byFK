-- =====================================================================================
--  Governance: who may see which row, and which columns are masked.
--  Run as ACCOUNTADMIN after the first `dbt build --target prod`, then:
--      dbt run-operation apply_governance_all --target prod
--  After that, every prod build re-attaches policies itself (macros/governance.sql).
--
--  Separation of duties
--    Security owns the policies and the entitlement table (this file, schema GOVERNANCE).
--    dbt owns the tables and only APPLIES the policies a model declares in its metadata.
--    An engineer can attach a policy; only security can change what it allows.
--
--  Who sees what (decided by the Snowflake user who logged in, never by the app)
--    CEO             every row
--    BRANCH_MANAGER  customers whose home branch is theirs
--    STAFF           the same rows; email, phone, date of birth and income masked
--    CUSTOMER        their own rows; no branch totals, no other customers
--    not in APP_USER allowed only with MERIDIAN_TRANSFORMER / ANALYST / ML in session;
--                    everyone else is denied (the Streamlit owner role included)
--  Country proof (end of this file). A country_code column is not a security boundary.
--  RAP_COUNTRY_SCOPE is. The Hong Kong user sees HK only. An unentitled user with the
--  same role sees zero rows. That role has no grant on MERIDIAN_RAW. Staff contact
--  fields stay masked. The branch and customer policies in this file are not rewritten.
-- =====================================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_BI_XS;

CREATE SCHEMA IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE
  COMMENT = 'Policies, tags and entitlements. Owned by security, applied by dbt.';

-- ------------------------------------------------------------------ entitlements
CREATE TABLE IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER (
    snowflake_user  STRING NOT NULL PRIMARY KEY,
    persona         STRING NOT NULL,     -- CEO | BRANCH_MANAGER | STAFF | CUSTOMER
    branch_id       NUMBER,
    customer_id     NUMBER,
    country_code    STRING,          -- country personas only. Branch personas stay NULL.
    granted_by      STRING DEFAULT CURRENT_USER(),
    granted_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Existing accounts already have the table. CREATE IF NOT EXISTS will not add the column.
ALTER TABLE MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
  ADD COLUMN IF NOT EXISTS country_code STRING;

-- ------------------------------------------------------------------ row access policies
-- IF NOT EXISTS on purpose. A policy attached to tables cannot be replaced, and dropping
-- it would expose every row until it is re-attached. The ALTER below updates the body
-- of a policy that is already attached.
--
-- Country isolation is a separate policy at the end of this file. These three policies
-- stay on branch_id and customer_id so the Mumbai personas keep their rows.
-- A policy body cannot contain a JOIN. Branch managers are matched with a scalar lookup
-- of their branch, then an EXISTS against ENT_CUSTOMER_BRANCH. Subqueries run with the
-- policy owner's privileges, so personas never need SELECT on those tables.
-- CURRENT_USER(), not CURRENT_ROLE(): inside a Streamlit app the role is the app
-- owner's for every viewer; the user is the viewer.
CREATE ROW ACCESS POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.RAP_CUSTOMER_SCOPE
AS (p_customer_id NUMBER) RETURNS BOOLEAN ->
    CASE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER() AND u.persona = 'CEO'
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
              AND u.persona = 'CUSTOMER'
              AND u.customer_id = p_customer_id
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.MARTS.ENT_CUSTOMER_BRANCH b
            WHERE b.customer_id = p_customer_id
              AND b.branch_id = (
                  SELECT MIN(u.branch_id)
                  FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
                  WHERE u.snowflake_user = CURRENT_USER()
                    AND u.persona IN ('BRANCH_MANAGER', 'STAFF')
              )
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
        ) THEN FALSE
        ELSE IS_ROLE_IN_SESSION('MERIDIAN_TRANSFORMER')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ANALYST')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ML')
    END;

ALTER ROW ACCESS POLICY MERIDIAN_ANALYTICS.GOVERNANCE.RAP_CUSTOMER_SCOPE SET BODY ->
    CASE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER() AND u.persona = 'CEO'
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
              AND u.persona = 'CUSTOMER'
              AND u.customer_id = p_customer_id
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.MARTS.ENT_CUSTOMER_BRANCH b
            WHERE b.customer_id = p_customer_id
              AND b.branch_id = (
                  SELECT MIN(u.branch_id)
                  FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
                  WHERE u.snowflake_user = CURRENT_USER()
                    AND u.persona IN ('BRANCH_MANAGER', 'STAFF')
              )
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
        ) THEN FALSE
        ELSE IS_ROLE_IN_SESSION('MERIDIAN_TRANSFORMER')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ANALYST')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ML')
    END;

-- dim_branch: a customer may see their own branch's address.
CREATE ROW ACCESS POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.RAP_BRANCH_SCOPE
AS (p_branch_id NUMBER) RETURNS BOOLEAN ->
    CASE
        WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u WHERE u.snowflake_user = CURRENT_USER())
        THEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
              AND (u.persona = 'CEO' OR u.branch_id = p_branch_id)
        )
        ELSE IS_ROLE_IN_SESSION('MERIDIAN_TRANSFORMER')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ANALYST')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ML')
    END;

-- Branch totals, accounts, balances, employees. The customer role is not even granted
-- these tables (dbt grants); the policy is the second lock.
CREATE ROW ACCESS POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.RAP_BRANCH_INTERNAL
AS (p_branch_id NUMBER) RETURNS BOOLEAN ->
    CASE
        WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u WHERE u.snowflake_user = CURRENT_USER())
        THEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
              AND (u.persona = 'CEO'
                   OR (u.persona IN ('BRANCH_MANAGER', 'STAFF') AND u.branch_id = p_branch_id))
        )
        ELSE IS_ROLE_IN_SESSION('MERIDIAN_TRANSFORMER')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ANALYST')
          OR IS_ROLE_IN_SESSION('MERIDIAN_ML')
    END;

-- ------------------------------------------------------------------ tag-based masking
-- One tag, one masking policy per data type. dbt sets the tag on a column; the policy
-- follows the tag. Adding a PII column is one line of model metadata.
CREATE TAG IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.PII
  ALLOWED_VALUES 'contact', 'contact_date', 'income'
  COMMENT = 'Personal data. Masked for STAFF.';

CREATE MASKING POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_STRING
AS (v STRING) RETURNS STRING ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona IN ('STAFF', 'COUNTRY_STAFF'))
         THEN '***' ELSE v END;
CREATE MASKING POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_NUMBER
AS (v NUMBER(18, 2)) RETURNS NUMBER(18, 2) ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona IN ('STAFF', 'COUNTRY_STAFF'))
         THEN NULL ELSE v END;
CREATE MASKING POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_DATE
AS (v DATE) RETURNS DATE ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona IN ('STAFF', 'COUNTRY_STAFF'))
         THEN NULL ELSE v END;

-- Fails harmlessly on a re-run, when the tag already carries these policies.
EXECUTE IMMEDIATE $$
BEGIN
    ALTER TAG MERIDIAN_ANALYTICS.GOVERNANCE.PII SET
      MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_STRING,
      MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_NUMBER,
      MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_DATE;
    RETURN 'masking policies attached to tag PII';
EXCEPTION
    WHEN OTHER THEN RETURN 'tag PII already has its masking policies: ' || SQLERRM;
END;
$$;

-- CREATE IF NOT EXISTS does not refresh a policy that already exists. SET BODY does.
-- STAFF stays masked. COUNTRY_STAFF is the country-demo staff persona. Branch managers,
-- the CEO and customers are not in this list, so their values stay visible.
ALTER MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_STRING SET BODY ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona IN ('STAFF', 'COUNTRY_STAFF'))
         THEN '***' ELSE v END;
ALTER MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_NUMBER SET BODY ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona IN ('STAFF', 'COUNTRY_STAFF'))
         THEN NULL ELSE v END;
ALTER MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_DATE SET BODY ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona IN ('STAFF', 'COUNTRY_STAFF'))
         THEN NULL ELSE v END;

-- dbt attaches policies and sets tags on the tables it owns.
GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_TRANSFORMER;
GRANT APPLY ON ROW ACCESS POLICY MERIDIAN_ANALYTICS.GOVERNANCE.RAP_CUSTOMER_SCOPE  TO ROLE MERIDIAN_TRANSFORMER;
GRANT APPLY ON ROW ACCESS POLICY MERIDIAN_ANALYTICS.GOVERNANCE.RAP_BRANCH_SCOPE    TO ROLE MERIDIAN_TRANSFORMER;
GRANT APPLY ON ROW ACCESS POLICY MERIDIAN_ANALYTICS.GOVERNANCE.RAP_BRANCH_INTERNAL TO ROLE MERIDIAN_TRANSFORMER;
GRANT APPLY ON TAG MERIDIAN_ANALYTICS.GOVERNANCE.PII TO ROLE MERIDIAN_TRANSFORMER;

-- ------------------------------------------------------------------ the app sees the viewer
-- Streamlit runs as its owner. READ SESSION lets CURRENT_USER() return the viewer.
-- Create the app with role MERIDIAN_APP. For a non-persona viewer the policies return
-- false, because MERIDIAN_APP is not one of the bypass roles: deny by default.
GRANT READ SESSION ON ACCOUNT TO ROLE MERIDIAN_APP;
GRANT CREATE STREAMLIT ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_APP;
GRANT CREATE STAGE     ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_APP;

CREATE OR REPLACE SECURE VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE AS
SELECT snowflake_user, persona, branch_id, customer_id
FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
WHERE snowflake_user = CURRENT_USER();

GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_APP;
GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_CEO;
GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_BRANCH_MANAGER;
GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_STAFF;
GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_CUSTOMER;
GRANT SELECT ON VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE TO ROLE MERIDIAN_APP;
GRANT SELECT ON VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE TO ROLE MERIDIAN_CEO;
GRANT SELECT ON VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE TO ROLE MERIDIAN_BRANCH_MANAGER;
GRANT SELECT ON VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE TO ROLE MERIDIAN_STAFF;
GRANT SELECT ON VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE TO ROLE MERIDIAN_CUSTOMER;

-- Cortex Analyst (if this account's region has it). The laptop app calls it as the
-- person who signed in, so each persona role needs this grant, not only the app owner.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE MERIDIAN_APP;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE MERIDIAN_CEO;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE MERIDIAN_BRANCH_MANAGER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE MERIDIAN_STAFF;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE MERIDIAN_CUSTOMER;

-- ------------------------------------------------------------------ four demo logins
-- Human users. Passwords are set by you in Snowsight (Admin -> Users & Roles -> user ->
-- Reset password), never in this file. A real bank federates these through its identity
-- provider (SAML/OAuth) with MFA; Snowflake still sees one user per person.
CREATE USER IF NOT EXISTS MERIDIAN_CEO          DEFAULT_ROLE = MERIDIAN_CEO            DEFAULT_WAREHOUSE = WH_BI_XS MUST_CHANGE_PASSWORD = TRUE;
CREATE USER IF NOT EXISTS MERIDIAN_BM_MUMBAI    DEFAULT_ROLE = MERIDIAN_BRANCH_MANAGER DEFAULT_WAREHOUSE = WH_BI_XS MUST_CHANGE_PASSWORD = TRUE;
CREATE USER IF NOT EXISTS MERIDIAN_STAFF_MUMBAI DEFAULT_ROLE = MERIDIAN_STAFF          DEFAULT_WAREHOUSE = WH_BI_XS MUST_CHANGE_PASSWORD = TRUE;
CREATE USER IF NOT EXISTS MERIDIAN_CUSTOMER     DEFAULT_ROLE = MERIDIAN_CUSTOMER       DEFAULT_WAREHOUSE = WH_BI_XS MUST_CHANGE_PASSWORD = TRUE;
GRANT ROLE MERIDIAN_CEO            TO USER MERIDIAN_CEO;
GRANT ROLE MERIDIAN_BRANCH_MANAGER TO USER MERIDIAN_BM_MUMBAI;
GRANT ROLE MERIDIAN_STAFF          TO USER MERIDIAN_STAFF_MUMBAI;
GRANT ROLE MERIDIAN_CUSTOMER       TO USER MERIDIAN_CUSTOMER;

-- Bind them to a real branch and a real customer. Nothing is invented: the ids come from
-- the gold layer. Read the result row on camera.
SET demo_branch_id = (
    SELECT COALESCE(
        (SELECT MIN(branch_id) FROM MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH WHERE branch_code = 'IN-MUM-0001'),
        (SELECT MIN(branch_id) FROM MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH WHERE country_code = 'IN' AND branch_id <> -1)
    )
);
SET demo_customer_id = (
    SELECT MIN(f.customer_id)
    FROM MERIDIAN_ANALYTICS.MARTS.ML_CUSTOMER_FEATURES f
    WHERE f.home_branch_id = $demo_branch_id AND f.has_active_card
);

MERGE INTO MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER t
USING (
    SELECT 'MERIDIAN_CEO' AS snowflake_user, 'CEO' AS persona, NULL::NUMBER AS branch_id, NULL::NUMBER AS customer_id
    UNION ALL SELECT 'MERIDIAN_BM_MUMBAI',    'BRANCH_MANAGER', $demo_branch_id, NULL
    UNION ALL SELECT 'MERIDIAN_STAFF_MUMBAI', 'STAFF',          $demo_branch_id, NULL
    UNION ALL SELECT 'MERIDIAN_CUSTOMER',     'CUSTOMER',       $demo_branch_id, $demo_customer_id
) s
ON t.snowflake_user = s.snowflake_user
WHEN MATCHED THEN UPDATE SET persona = s.persona, branch_id = s.branch_id, customer_id = s.customer_id,
                             granted_by = CURRENT_USER(), granted_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (snowflake_user, persona, branch_id, customer_id)
                      VALUES (s.snowflake_user, s.persona, s.branch_id, s.customer_id);

SELECT u.*, b.branch_code
FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
LEFT JOIN MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH b ON b.branch_id = u.branch_id;
-- A NULL customer_id for MERIDIAN_CUSTOMER means that branch has no cardholder yet:
-- seed cards (08_seed_cards.sql), reload, rebuild, run this file again.

-- ------------------------------------------------------------------ prove it
-- Log in as each user (log out first: USE ROLE does not change CURRENT_USER()).
--   SELECT * FROM MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE;
--   SELECT COUNT(*) FROM MERIDIAN_ANALYTICS.MARTS.FCT_CARD_AUTHORIZATIONS;
--   SELECT email, phone, date_of_birth FROM MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER_CURRENT LIMIT 5;
-- Expect: CEO > branch manager = staff > customer, and '***' / NULL contact columns for staff.
--
-- Audit who read what, afterwards (Enterprise edition, ~3h latency):
--   SELECT user_name, query_start_time, direct_objects_accessed
--   FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
--   WHERE user_name LIKE 'MERIDIAN_%' ORDER BY query_start_time DESC LIMIT 50;
--
-- After the app exists:
--   GRANT USAGE ON STREAMLIT MERIDIAN_ANALYTICS.GOVERNANCE.MERIDIAN_BANK TO ROLE MERIDIAN_CEO;   (and the other three)

-- COUNTRY ENTITLEMENT
-- A country_code value on dim_branch, dim_customer, dim_merchant or dim_sale_event names
-- the country. It does not hide the other countries. This section projects those columns
-- into one security-owned table and attaches RAP_COUNTRY_SCOPE to that column.
--
-- The branch policies are not changed. A Snowflake table accepts one row access policy,
-- and dim_branch / dim_customer already use the branch and customer policies. Putting a
-- second predicate into those policies would be a rewrite of the Mumbai personas.
--
-- Seeded countries are IN, AE, GB, US, SG. HK is not one of them. One fixture row with
-- country_code HK is loaded so the Hong Kong user has a positive row to see. Every other
-- row is copied from the marts, so the same user must not see India, Singapore, and the rest.
--
-- Three users share MERIDIAN_COUNTRY_OFFICER. The role is not the boundary.
--   MERIDIAN_HK_OFFICER   COUNTRY_OFFICER  HK    sees only HK, email in clear
--   MERIDIAN_HK_STAFF     COUNTRY_STAFF    HK    sees only HK, email masked as ***
--   MERIDIAN_UNENTITLED   (no APP_USER row)      sees zero rows (deny by default)
-- None of them is granted MERIDIAN_RAW. None of them is granted the marts.
-- =====================================================================================

CREATE ROLE IF NOT EXISTS MERIDIAN_COUNTRY_OFFICER
  COMMENT = 'Shared by the country proof users. Isolation is RAP_COUNTRY_SCOPE, not this role.';
GRANT ROLE MERIDIAN_COUNTRY_OFFICER TO ROLE SYSADMIN;
GRANT USAGE ON WAREHOUSE WH_BI_XS TO ROLE MERIDIAN_COUNTRY_OFFICER;
GRANT USAGE ON DATABASE MERIDIAN_ANALYTICS TO ROLE MERIDIAN_COUNTRY_OFFICER;
GRANT USAGE ON SCHEMA MERIDIAN_ANALYTICS.GOVERNANCE TO ROLE MERIDIAN_COUNTRY_OFFICER;

CREATE ROW ACCESS POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.RAP_COUNTRY_SCOPE
AS (p_country_code STRING) RETURNS BOOLEAN ->
    CASE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER() AND u.persona = 'CEO'
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
              AND u.persona IN ('COUNTRY_OFFICER', 'COUNTRY_STAFF')
              AND u.country_code IS NOT NULL
              AND u.country_code = p_country_code
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
        ) THEN FALSE
        ELSE FALSE
    END;

ALTER ROW ACCESS POLICY MERIDIAN_ANALYTICS.GOVERNANCE.RAP_COUNTRY_SCOPE SET BODY ->
    CASE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER() AND u.persona = 'CEO'
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
              AND u.persona IN ('COUNTRY_OFFICER', 'COUNTRY_STAFF')
              AND u.country_code IS NOT NULL
              AND u.country_code = p_country_code
        ) THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER u
            WHERE u.snowflake_user = CURRENT_USER()
        ) THEN FALSE
        ELSE FALSE
    END;

-- Load before the policy is attached. A policy on the target would filter this INSERT.
CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART (
    source_model   STRING NOT NULL,
    business_key   STRING NOT NULL,
    country_code   STRING,
    label          STRING,
    contact_email  STRING
)
COMMENT = 'Country proof. country_code is projected from the existing marts. Branch policies stay on those marts.';

INSERT INTO MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART
    (source_model, business_key, country_code, label, contact_email)
SELECT 'DIM_BRANCH', branch_id::STRING, country_code, branch_name, NULL
FROM MERIDIAN_ANALYTICS.MARTS.DIM_BRANCH
WHERE branch_id <> -1
UNION ALL
SELECT 'DIM_CUSTOMER', customer_id::STRING, country_code, full_name, NULL
FROM MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER
WHERE is_current AND customer_id <> -1
UNION ALL
SELECT 'DIM_MERCHANT', merchant_id::STRING, country_code, merchant_name, NULL
FROM MERIDIAN_ANALYTICS.MARTS.DIM_MERCHANT
WHERE merchant_id <> -1
UNION ALL
SELECT 'DIM_SALE_EVENT', sale_event_id::STRING, country_code, event_name, NULL
FROM MERIDIAN_ANALYTICS.MARTS.DIM_SALE_EVENT
WHERE sale_event_id <> -1
UNION ALL
SELECT
    'HK_ENTITLEMENT_FIXTURE',
    'HK-CENTRAL-0001',
    'HK',
    'Hong Kong Central (fixture: seeded countries are IN, AE, GB, US, SG)',
    'hk.customer@bank.example';

-- Counts are taken before the policy exists, then stored where the policy cannot hide them.
CREATE OR REPLACE TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_DEMO_EXPECTATION (
    hk_rows            NUMBER NOT NULL,
    other_country_rows NUMBER NOT NULL
);

INSERT INTO MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_DEMO_EXPECTATION (hk_rows, other_country_rows)
SELECT
    (SELECT COUNT(*) FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART WHERE country_code = 'HK'),
    (SELECT COUNT(*) FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART WHERE country_code IS DISTINCT FROM 'HK');

ALTER TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART
  ADD ROW ACCESS POLICY MERIDIAN_ANALYTICS.GOVERNANCE.RAP_COUNTRY_SCOPE ON (country_code);

ALTER TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART
  MODIFY COLUMN contact_email
  SET MASKING POLICY MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_STRING;

GRANT SELECT ON TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART TO ROLE MERIDIAN_COUNTRY_OFFICER;
GRANT SELECT ON TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART TO ROLE MERIDIAN_CEO;
GRANT SELECT ON VIEW MERIDIAN_ANALYTICS.GOVERNANCE.V_MY_SCOPE TO ROLE MERIDIAN_COUNTRY_OFFICER;

-- No USAGE, SELECT, or any other privilege on MERIDIAN_RAW is granted to this role.

CREATE USER IF NOT EXISTS MERIDIAN_HK_OFFICER
  DEFAULT_ROLE = MERIDIAN_COUNTRY_OFFICER
  DEFAULT_WAREHOUSE = WH_BI_XS
  MUST_CHANGE_PASSWORD = TRUE;
CREATE USER IF NOT EXISTS MERIDIAN_HK_STAFF
  DEFAULT_ROLE = MERIDIAN_COUNTRY_OFFICER
  DEFAULT_WAREHOUSE = WH_BI_XS
  MUST_CHANGE_PASSWORD = TRUE;
CREATE USER IF NOT EXISTS MERIDIAN_UNENTITLED
  DEFAULT_ROLE = MERIDIAN_COUNTRY_OFFICER
  DEFAULT_WAREHOUSE = WH_BI_XS
  MUST_CHANGE_PASSWORD = TRUE;
GRANT ROLE MERIDIAN_COUNTRY_OFFICER TO USER MERIDIAN_HK_OFFICER;
GRANT ROLE MERIDIAN_COUNTRY_OFFICER TO USER MERIDIAN_HK_STAFF;
GRANT ROLE MERIDIAN_COUNTRY_OFFICER TO USER MERIDIAN_UNENTITLED;

-- Branch personas keep a NULL country. Their policies do not read this column.
UPDATE MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
SET country_code = NULL
WHERE snowflake_user IN (
    'MERIDIAN_CEO', 'MERIDIAN_BM_MUMBAI', 'MERIDIAN_STAFF_MUMBAI', 'MERIDIAN_CUSTOMER'
);

MERGE INTO MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER t
USING (
    SELECT 'MERIDIAN_HK_OFFICER' AS snowflake_user, 'COUNTRY_OFFICER' AS persona,
           NULL::NUMBER AS branch_id, NULL::NUMBER AS customer_id, 'HK' AS country_code
    UNION ALL
    SELECT 'MERIDIAN_HK_STAFF', 'COUNTRY_STAFF', NULL::NUMBER, NULL::NUMBER, 'HK'
) s
ON t.snowflake_user = s.snowflake_user
WHEN MATCHED THEN UPDATE SET
    persona = s.persona,
    branch_id = s.branch_id,
    customer_id = s.customer_id,
    country_code = s.country_code,
    granted_by = CURRENT_USER(),
    granted_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (snowflake_user, persona, branch_id, customer_id, country_code)
    VALUES (s.snowflake_user, s.persona, s.branch_id, s.customer_id, s.country_code);

DELETE FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
WHERE snowflake_user = 'MERIDIAN_UNENTITLED';

-- SHOW GRANTS columns are lowercase in RESULT_SCAN and must be quoted.
SHOW GRANTS TO ROLE MERIDIAN_COUNTRY_OFFICER;
CREATE OR REPLACE TEMPORARY TABLE MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_ROLE_GRANT_CHECK AS
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Expect zero rows: the country role cannot read raw.
SELECT "privilege", "granted_on", "name"
FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_ROLE_GRANT_CHECK
WHERE "name" ILIKE '%MERIDIAN_RAW%';

EXECUTE IMMEDIATE $$
DECLARE
    branch_personas INTEGER;
    hk_officer INTEGER;
    hk_staff INTEGER;
    unentitled INTEGER;
    expected_hk INTEGER;
    expected_other INTEGER;
    raw_grants INTEGER;
    mask_ddl STRING;
    country_ddl STRING;
    branch_ddl STRING;
BEGIN
    SELECT COUNT(*) INTO :branch_personas
    FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
    WHERE (snowflake_user = 'MERIDIAN_CEO' AND persona = 'CEO' AND country_code IS NULL)
       OR (snowflake_user = 'MERIDIAN_BM_MUMBAI' AND persona = 'BRANCH_MANAGER' AND country_code IS NULL)
       OR (snowflake_user = 'MERIDIAN_STAFF_MUMBAI' AND persona = 'STAFF' AND country_code IS NULL)
       OR (snowflake_user = 'MERIDIAN_CUSTOMER' AND persona = 'CUSTOMER' AND country_code IS NULL);
    IF (branch_personas <> 4) THEN
        RAISE STATEMENT_ERROR(-20012, 'branch personas changed while adding country entitlements');
    END IF;

    SELECT COUNT(*) INTO :hk_officer
    FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
    WHERE snowflake_user = 'MERIDIAN_HK_OFFICER'
      AND persona = 'COUNTRY_OFFICER'
      AND country_code = 'HK'
      AND branch_id IS NULL;
    SELECT COUNT(*) INTO :hk_staff
    FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
    WHERE snowflake_user = 'MERIDIAN_HK_STAFF'
      AND persona = 'COUNTRY_STAFF'
      AND country_code = 'HK'
      AND branch_id IS NULL;
    SELECT COUNT(*) INTO :unentitled
    FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
    WHERE snowflake_user = 'MERIDIAN_UNENTITLED';
    IF (hk_officer <> 1 OR hk_staff <> 1 OR unentitled <> 0) THEN
        RAISE STATEMENT_ERROR(-20013, 'HK entitlement or deny-by-default user is wrong');
    END IF;

    SELECT hk_rows, other_country_rows INTO :expected_hk, :expected_other
    FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_DEMO_EXPECTATION;
    IF (expected_hk < 1 OR expected_other < 1) THEN
        RAISE STATEMENT_ERROR(-20014, 'country projection has no HK row or no other country from the marts');
    END IF;

    SELECT COUNT(*) INTO :raw_grants
    FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_ROLE_GRANT_CHECK
    WHERE "name" ILIKE '%MERIDIAN_RAW%';
    IF (raw_grants > 0) THEN
        RAISE STATEMENT_ERROR(-20015, 'MERIDIAN_COUNTRY_OFFICER has a grant on MERIDIAN_RAW');
    END IF;

    SELECT GET_DDL('MASKING_POLICY', 'MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_STRING') INTO :mask_ddl;
    IF (POSITION('COUNTRY_STAFF', mask_ddl) = 0 OR POSITION('''STAFF''', mask_ddl) = 0) THEN
        RAISE STATEMENT_ERROR(-20016, 'string masking policy does not mask STAFF and COUNTRY_STAFF');
    END IF;

    SELECT GET_DDL('ROW_ACCESS_POLICY', 'MERIDIAN_ANALYTICS.GOVERNANCE.RAP_COUNTRY_SCOPE') INTO :country_ddl;
    IF (POSITION('COUNTRY_OFFICER', country_ddl) = 0 OR POSITION('FALSE', country_ddl) = 0) THEN
        RAISE STATEMENT_ERROR(-20017, 'RAP_COUNTRY_SCOPE is missing the HK match or the deny path');
    END IF;

    SELECT GET_DDL('ROW_ACCESS_POLICY', 'MERIDIAN_ANALYTICS.GOVERNANCE.RAP_CUSTOMER_SCOPE') INTO :branch_ddl;
    IF (POSITION('BRANCH_MANAGER', branch_ddl) = 0 OR POSITION('COUNTRY_OFFICER', branch_ddl) > 0) THEN
        RAISE STATEMENT_ERROR(-20018, 'RAP_CUSTOMER_SCOPE was rewritten for country access');
    END IF;

    RETURN 'country proof installed: HK rows=' || expected_hk || ' other country rows=' || expected_other;
END;
$$;

-- Log out between users. USE ROLE does not change CURRENT_USER().
--   USE ROLE MERIDIAN_COUNTRY_OFFICER;  -- then log in as the user below
--
-- MERIDIAN_HK_OFFICER
--   SELECT country_code, COUNT(*) FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART GROUP BY 1;
--   Expect one group: HK.
--   SELECT contact_email FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART
--   WHERE source_model = 'HK_ENTITLEMENT_FIXTURE';
--   Expect hk.customer@bank.example.
--   SELECT * FROM MERIDIAN_RAW.POSTGRES_REF.COUNTRIES;
--   Expect insufficient privileges.
--
-- MERIDIAN_HK_STAFF
--   Same country_code result: HK only.
--   contact_email for the fixture is ***.
--
-- MERIDIAN_UNENTITLED
--   SELECT COUNT(*) FROM MERIDIAN_ANALYTICS.GOVERNANCE.COUNTRY_SCOPED_MART;
--   Expect 0. The role has SELECT. The missing APP_USER row denies every row.
--
-- MERIDIAN_BM_MUMBAI (unchanged)
--   SELECT COUNT(*) FROM MERIDIAN_ANALYTICS.MARTS.FCT_CARD_AUTHORIZATIONS;
--   Still one branch. This user is not granted COUNTRY_SCOPED_MART.
--   SELECT email FROM MERIDIAN_ANALYTICS.MARTS.DIM_CUSTOMER LIMIT 5;
--   Still unmasked. STAFF remains the masked branch persona.
