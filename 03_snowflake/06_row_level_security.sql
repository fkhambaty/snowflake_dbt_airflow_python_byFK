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
    granted_by      STRING DEFAULT CURRENT_USER(),
    granted_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ------------------------------------------------------------------ row access policies
-- IF NOT EXISTS on purpose. A policy attached to tables cannot be replaced, and dropping
-- it would expose every row until it is re-attached. The ALTER below updates the body
-- of a policy that is already attached.
--
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
                      WHERE snowflake_user = CURRENT_USER() AND persona = 'STAFF')
         THEN '***' ELSE v END;
CREATE MASKING POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_NUMBER
AS (v NUMBER(18, 2)) RETURNS NUMBER(18, 2) ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona = 'STAFF')
         THEN NULL ELSE v END;
CREATE MASKING POLICY IF NOT EXISTS MERIDIAN_ANALYTICS.GOVERNANCE.MASK_PII_DATE
AS (v DATE) RETURNS DATE ->
    CASE WHEN EXISTS (SELECT 1 FROM MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER
                      WHERE snowflake_user = CURRENT_USER() AND persona = 'STAFF')
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
