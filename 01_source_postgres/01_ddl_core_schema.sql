-- =====================================================================================
--  MERIDIAN BANK  |  Core banking OLTP schema (PostgreSQL 16)
--  Normalised (3NF). This is the SOURCE system. The warehouse is built from it, never
--  the other way round.
--
--  Schemas
--    ref  : slow-changing reference data owned by Treasury / Product teams
--    core : the operational heart (customers, accounts, transactions, loans)
--    cdc  : change-data-capture helpers (delete log) consumed by the ingestion layer
--
--  Conventions worth teaching
--    * every table has created_at / updated_at (TIMESTAMPTZ) -> watermark CDC works
--    * surrogate integer PKs + human readable business keys (customer_number, ...)
--    * TIMESTAMPTZ everywhere: Postgres stores UTC; the warehouse standardises on UTC
--    * money is NUMERIC, never FLOAT
--
--  DELIBERATE PERFORMANCE TRAPS (fixed live in 06_performance_lab)
--    * no index on core.transactions(updated_at)             -> extraction does a seq scan
--    * no index on core.transactions(account_id, transaction_ts) -> statement queries crawl
-- =====================================================================================
-- Execute the whole script in DBeaver, connected to meridian_core.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS cdc;

-- -------------------------------------------------------------------------------------
-- ref.currencies
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.currencies (
    currency_code   CHAR(3)      PRIMARY KEY,
    currency_name   TEXT         NOT NULL,
    symbol          TEXT         NOT NULL,
    minor_units     SMALLINT     NOT NULL DEFAULT 2,       -- decimals (JPY would be 0)
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- ref.countries
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.countries (
    country_code    CHAR(2)      PRIMARY KEY,               -- ISO 3166-1 alpha-2
    country_name    TEXT         NOT NULL,
    currency_code   CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    region          TEXT         NOT NULL,                  -- APAC / MEA / EUROPE / AMERICAS
    timezone        TEXT         NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- ref.fx_rates  (1 unit of from_currency = rate units of to_currency)
-- Treasury publishes one closing rate per business day. Weekends/holidays have no row:
-- the warehouse must forward-fill (taught in dbt intermediate layer).
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.fx_rates (
    fx_rate_id      BIGSERIAL    PRIMARY KEY,
    rate_date       DATE         NOT NULL,
    from_currency   CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    to_currency     CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    rate            NUMERIC(18,8) NOT NULL CHECK (rate > 0),
    source          TEXT         NOT NULL DEFAULT 'TREASURY_CLOSE',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (rate_date, from_currency, to_currency)
);

-- -------------------------------------------------------------------------------------
-- ref.channels
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.channels (
    channel_id      SMALLSERIAL  PRIMARY KEY,
    channel_code    TEXT         NOT NULL UNIQUE,            -- BRANCH, ATM, MOBILE, ...
    channel_name    TEXT         NOT NULL,
    is_digital      BOOLEAN      NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- ref.products
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.products (
    product_id        SERIAL       PRIMARY KEY,
    product_code      TEXT         NOT NULL UNIQUE,
    product_name      TEXT         NOT NULL,
    product_category  TEXT         NOT NULL CHECK (product_category IN ('DEPOSIT','LOAN','CARD')),
    product_type      TEXT         NOT NULL CHECK (product_type IN
                        ('SAVINGS','CURRENT','FIXED_DEPOSIT','PERSONAL_LOAN','HOME_LOAN','AUTO_LOAN','CREDIT_CARD')),
    base_interest_rate NUMERIC(6,4) NOT NULL DEFAULT 0,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- core.branches  (520 of them)
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.branches (
    branch_id       SERIAL       PRIMARY KEY,
    branch_code     TEXT         NOT NULL UNIQUE,            -- e.g. IN-MUM-0001
    branch_name     TEXT         NOT NULL,
    country_code    CHAR(2)      NOT NULL REFERENCES ref.countries(country_code),
    city            TEXT         NOT NULL,
    state_region    TEXT,
    branch_type     TEXT         NOT NULL CHECK (branch_type IN ('FULL_SERVICE','PREMIUM','RURAL','DIGITAL_HUB')),
    opened_date     DATE         NOT NULL,
    status          TEXT         NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RENOVATION','CLOSED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- core.employees
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.employees (
    employee_id     SERIAL       PRIMARY KEY,
    employee_code   TEXT         NOT NULL UNIQUE,
    branch_id       INT          NOT NULL REFERENCES core.branches(branch_id),
    full_name       TEXT         NOT NULL,
    job_title       TEXT         NOT NULL CHECK (job_title IN
                        ('TELLER','RELATIONSHIP_MANAGER','LOAN_OFFICER','BRANCH_MANAGER','OPERATIONS')),
    hire_date       DATE         NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- core.customers
-- segment / kyc_status / risk_rating / home_branch_id change over time -> SCD2 candidates
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.customers (
    customer_id     BIGSERIAL    PRIMARY KEY,
    customer_number TEXT         NOT NULL UNIQUE,            -- CIF number, business key
    first_name      TEXT         NOT NULL,
    last_name       TEXT         NOT NULL,
    date_of_birth   DATE         NOT NULL,
    gender          CHAR(1)      CHECK (gender IN ('M','F','O')),
    email           TEXT,
    phone           TEXT,
    kyc_status      TEXT         NOT NULL DEFAULT 'PENDING' CHECK (kyc_status IN ('PENDING','VERIFIED','EXPIRED')),
    segment         TEXT         NOT NULL DEFAULT 'RETAIL'  CHECK (segment IN ('RETAIL','PREMIUM','PRIVATE','SME')),
    risk_rating     TEXT         NOT NULL DEFAULT 'LOW'     CHECK (risk_rating IN ('LOW','MEDIUM','HIGH')),
    home_branch_id  INT          NOT NULL REFERENCES core.branches(branch_id),
    country_code    CHAR(2)      NOT NULL REFERENCES ref.countries(country_code),
    city            TEXT,
    onboarded_at    TIMESTAMPTZ  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- core.accounts
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.accounts (
    account_id      BIGSERIAL    PRIMARY KEY,
    account_number  TEXT         NOT NULL UNIQUE,
    product_id      INT          NOT NULL REFERENCES ref.products(product_id),
    branch_id       INT          NOT NULL REFERENCES core.branches(branch_id),
    currency_code   CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    status          TEXT         NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DORMANT','FROZEN','CLOSED')),
    opened_date     DATE         NOT NULL,
    closed_date     DATE,
    current_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit_limit    NUMERIC(18,2),
    interest_rate   NUMERIC(6,4),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (closed_date IS NULL OR closed_date >= opened_date)
);

-- -------------------------------------------------------------------------------------
-- core.account_holders  (many-to-many: joint accounts!) -> bridge table in the warehouse
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.account_holders (
    account_id      BIGINT       NOT NULL REFERENCES core.accounts(account_id),
    customer_id     BIGINT       NOT NULL REFERENCES core.customers(customer_id),
    holder_role     TEXT         NOT NULL CHECK (holder_role IN ('PRIMARY','JOINT','AUTHORISED_SIGNATORY')),
    added_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, customer_id)
);

-- -------------------------------------------------------------------------------------
-- core.transactions  (the big one; millions of rows; mutable: PENDING -> POSTED/REVERSED)
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.transactions (
    transaction_id      BIGSERIAL    PRIMARY KEY,
    account_id          BIGINT       NOT NULL REFERENCES core.accounts(account_id),
    transaction_ts      TIMESTAMPTZ  NOT NULL,
    transaction_type    TEXT         NOT NULL CHECK (transaction_type IN
                          ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','CARD_PAYMENT',
                           'FEE','INTEREST','LOAN_EMI','SALARY_CREDIT','REFUND')),
    amount              NUMERIC(18,2) NOT NULL CHECK (amount > 0),   -- always positive; direction is derived from type
    currency_code       CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    channel_id          SMALLINT     NOT NULL REFERENCES ref.channels(channel_id),
    branch_id           INT          REFERENCES core.branches(branch_id),     -- NULL for digital channels
    employee_id         INT          REFERENCES core.employees(employee_id),  -- teller, if any
    counterparty_account TEXT,
    merchant_category   TEXT,                                                 -- for card payments
    status              TEXT         NOT NULL DEFAULT 'POSTED' CHECK (status IN ('PENDING','POSTED','REVERSED')),
    reference_no        TEXT         NOT NULL DEFAULT encode(gen_random_bytes(8), 'hex'),
    description         TEXT,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);
-- NOTE: intentionally NO secondary indexes here. See 06_performance_lab/01_postgres_missing_index.sql

-- -------------------------------------------------------------------------------------
-- core.loan_applications  (a pipeline with milestones -> accumulating snapshot fact)
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.loan_applications (
    application_id    BIGSERIAL    PRIMARY KEY,
    customer_id       BIGINT       NOT NULL REFERENCES core.customers(customer_id),
    branch_id         INT          NOT NULL REFERENCES core.branches(branch_id),
    product_id        INT          NOT NULL REFERENCES ref.products(product_id),
    loan_officer_id   INT          REFERENCES core.employees(employee_id),
    amount_requested  NUMERIC(18,2) NOT NULL CHECK (amount_requested > 0),
    amount_approved   NUMERIC(18,2),
    currency_code     CHAR(3)      NOT NULL REFERENCES ref.currencies(currency_code),
    status            TEXT         NOT NULL DEFAULT 'APPLIED' CHECK (status IN
                        ('APPLIED','UNDER_REVIEW','APPROVED','REJECTED','DISBURSED','CLOSED')),
    applied_at        TIMESTAMPTZ  NOT NULL,
    reviewed_at       TIMESTAMPTZ,
    approved_at       TIMESTAMPTZ,
    rejected_at       TIMESTAMPTZ,
    disbursed_at      TIMESTAMPTZ,
    closed_at         TIMESTAMPTZ,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------------------------
-- cdc.deleted_records  -- hard deletes are invisible to a watermark query; a trigger logs them
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cdc.deleted_records (
    deleted_record_id BIGSERIAL    PRIMARY KEY,
    schema_name       TEXT         NOT NULL,
    table_name        TEXT         NOT NULL,
    pk_value          TEXT         NOT NULL,
    deleted_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_deleted_records_deleted_at ON cdc.deleted_records (deleted_at);

-- Lookups the simulator and lessons use heavily (these are NOT the perf-lab traps)
CREATE INDEX IF NOT EXISTS ix_accounts_branch      ON core.accounts (branch_id);
CREATE INDEX IF NOT EXISTS ix_accounts_status      ON core.accounts (status);
CREATE INDEX IF NOT EXISTS ix_customers_home_branch ON core.customers (home_branch_id);
CREATE INDEX IF NOT EXISTS ix_employees_branch    ON core.employees (branch_id);
CREATE INDEX IF NOT EXISTS ix_account_holders_customer ON core.account_holders (customer_id);
CREATE INDEX IF NOT EXISTS ix_loan_apps_status     ON core.loan_applications (status);

COMMENT ON TABLE core.transactions IS 'Ledger of customer account movements. Mutable status. Amount is positive; direction comes from transaction_type.';
COMMENT ON TABLE core.account_holders IS 'Joint accounts make this many-to-many. Becomes bridge_account_customer in the warehouse.';
COMMENT ON TABLE ref.fx_rates IS 'Daily treasury close. Weekends have no rows on purpose.';
