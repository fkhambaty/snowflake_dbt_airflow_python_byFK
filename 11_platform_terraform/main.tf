# Meridian platform as code: roles, warehouses, databases, raw schemas, role hierarchy.
#
# The SQL in 03_snowflake/01-02 creates the same objects so the course can show every
# statement. A team runs this instead: reviewed in a pull request, planned before it is
# applied, and drift is visible (`terraform plan` on a schedule).
#
# What is NOT here, on purpose:
#   * tables, views, marts       -> dbt owns them (grants too, via `grants:` config)
#   * row access / masking policy -> security owns them (06_row_level_security.sql)
#   * human users                 -> the identity provider (SCIM) creates them
# One owner per object type. Two tools managing the same grant fight forever.

terraform {
  required_version = ">= 1.6"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 1.0, < 3.0"
    }
  }
}

# Credentials come from the environment, never from this file:
#   SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME, SNOWFLAKE_USER,
#   SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT, SNOWFLAKE_PRIVATE_KEY_PATH, SNOWFLAKE_ROLE=ACCOUNTADMIN
provider "snowflake" {}

locals {
  functional_roles = {
    MERIDIAN_LOADER      = "Ingestion service: PUT/COPY into MERIDIAN_RAW"
    MERIDIAN_TRANSFORMER = "dbt: builds MERIDIAN_ANALYTICS from MERIDIAN_RAW"
    MERIDIAN_ANALYST     = "Read-only consumer of MARTS, whole bank"
    MERIDIAN_ML          = "Training job: reads gold, writes MERIDIAN_RAW.ML"
    MERIDIAN_APP         = "Owner of the Streamlit app. Row policies deny it by default."
  }
  persona_roles = {
    MERIDIAN_CEO            = "Persona: whole bank"
    MERIDIAN_BRANCH_MANAGER = "Persona: one branch"
    MERIDIAN_STAFF          = "Persona: one branch, PII masked"
    MERIDIAN_CUSTOMER       = "Persona: own rows"
  }
  all_roles = merge(local.functional_roles, local.persona_roles)

  warehouses = {
    WH_INGEST_XS    = { size = "XSMALL", suspend = 60, comment = "COPY INTO raw" }
    WH_TRANSFORM_XS = { size = "XSMALL", suspend = 60, comment = "dbt default" }
    WH_TRANSFORM_M  = { size = "MEDIUM", suspend = 60, comment = "Performance lab: scale-up experiments" }
    WH_BI_XS        = { size = "XSMALL", suspend = 120, comment = "Dashboards, the app, ad hoc" }
  }

  # role -> warehouses it may use
  warehouse_usage = {
    MERIDIAN_LOADER         = ["WH_INGEST_XS"]
    MERIDIAN_TRANSFORMER    = ["WH_TRANSFORM_XS", "WH_TRANSFORM_M"]
    MERIDIAN_ML             = ["WH_TRANSFORM_XS"]
    MERIDIAN_ANALYST        = ["WH_BI_XS"]
    MERIDIAN_APP            = ["WH_BI_XS"]
    MERIDIAN_CEO            = ["WH_BI_XS"]
    MERIDIAN_BRANCH_MANAGER = ["WH_BI_XS"]
    MERIDIAN_STAFF          = ["WH_BI_XS"]
    MERIDIAN_CUSTOMER       = ["WH_BI_XS"]
  }
  warehouse_grants = merge([
    for role, whs in local.warehouse_usage : { for wh in whs : "${role}/${wh}" => { role = role, warehouse = wh } }
  ]...)

  raw_schemas = ["POSTGRES_CORE", "POSTGRES_REF", "POSTGRES_CDC", "CONTROL", "PERF_LAB", "ML"]
}

# ------------------------------------------------------------------ roles and hierarchy
resource "snowflake_account_role" "this" {
  for_each = local.all_roles
  name     = each.key
  comment  = each.value
}

resource "snowflake_grant_account_role" "to_sysadmin" {
  for_each         = local.all_roles
  role_name        = snowflake_account_role.this[each.key].name
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_account_role" "analyst_to_transformer" {
  role_name        = snowflake_account_role.this["MERIDIAN_ANALYST"].name
  parent_role_name = snowflake_account_role.this["MERIDIAN_TRANSFORMER"].name
}

# ------------------------------------------------------------------ compute and cost guard
resource "snowflake_resource_monitor" "trial" {
  name                      = "RM_MERIDIAN_TRIAL"
  credit_quota              = var.monthly_credit_quota
  frequency                 = "MONTHLY"
  start_timestamp           = "IMMEDIATELY"
  notify_triggers           = [75]
  suspend_trigger           = 90
  suspend_immediate_trigger = 100
}

resource "snowflake_warehouse" "this" {
  for_each            = local.warehouses
  name                = each.key
  warehouse_size      = each.value.size
  auto_suspend        = each.value.suspend
  auto_resume         = true
  initially_suspended = true
  resource_monitor    = snowflake_resource_monitor.trial.name
  comment             = each.value.comment
}

resource "snowflake_grant_privileges_to_account_role" "warehouse_usage" {
  for_each          = local.warehouse_grants
  account_role_name = snowflake_account_role.this[each.value.role].name
  privileges        = each.value.role == "MERIDIAN_LOADER" || each.value.role == "MERIDIAN_TRANSFORMER" ? ["USAGE", "OPERATE"] : ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.this[each.value.warehouse].name
  }
}

# ------------------------------------------------------------------ storage
resource "snowflake_database" "raw" {
  name                        = "MERIDIAN_RAW"
  comment                     = "Landing zone replicated from Postgres (append-only), plus ML output"
  data_retention_time_in_days = 7
}

resource "snowflake_database" "analytics" {
  name    = "MERIDIAN_ANALYTICS"
  comment = "dbt-managed warehouse (staging -> intermediate -> marts)"
}

resource "snowflake_schema" "raw" {
  for_each = toset(local.raw_schemas)
  database = snowflake_database.raw.name
  name     = each.key
}

# Ownership follows the workload: the loader owns raw, dbt owns analytics.
resource "snowflake_grant_ownership" "raw_db" {
  account_role_name   = snowflake_account_role.this["MERIDIAN_LOADER"].name
  outbound_privileges = "COPY"
  on {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

resource "snowflake_grant_ownership" "analytics_db" {
  account_role_name   = snowflake_account_role.this["MERIDIAN_TRANSFORMER"].name
  outbound_privileges = "COPY"
  on {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analytics_usage" {
  for_each          = toset(["MERIDIAN_ANALYST", "MERIDIAN_ML", "MERIDIAN_APP", "MERIDIAN_CEO", "MERIDIAN_BRANCH_MANAGER", "MERIDIAN_STAFF", "MERIDIAN_CUSTOMER"])
  account_role_name = snowflake_account_role.this[each.key].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_reads_raw" {
  account_role_name = snowflake_account_role.this["MERIDIAN_TRANSFORMER"].name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.raw.name
    }
  }
}
