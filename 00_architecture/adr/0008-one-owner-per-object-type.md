# 0008. One owner per object type: Terraform, dbt, security SQL

**Status:** Accepted

## Context
Snowflake objects can be created by worksheets, Terraform, dbt, or the app. When two tools
manage the same grant, each run undoes the other's changes, and nobody can say what the
intended state is.

## Decision
| Object | Owner | Where |
|---|---|---|
| Roles, role hierarchy, warehouses, resource monitors, databases, raw schemas, warehouse/database grants | Terraform | `11_platform_terraform/` |
| Analytics schemas, tables, views, **SELECT grants on marts**, tests, contracts | dbt | `04_dbt_meridian_dw/` (`grants:` config) |
| Row access and masking policies, PII tag, `APP_USER` entitlements | Security team | `03_snowflake/06_row_level_security.sql` |
| Human users | Identity provider (SCIM) | Not in this repo |
| Raw tables, stages, file formats | Ingestion | `03_snowflake/03_...sql` |

The SQL in `03_snowflake/01–02` creates the same platform objects as Terraform, so the
course can show every statement. In a real account you run one or the other, not both.

## Consequences
* Grants on marts are reviewed in the same pull request as the model that creates them.
* A drift check (`terraform plan` with no changes expected) can run nightly.
* The old pattern, database-wide `GRANT SELECT ON FUTURE TABLES` to analysts, is gone. It
  exposed staging PII to anyone holding the analyst role.

## Revisit when
The account grows to many teams. Then move to per-domain databases with database roles,
still one owner per object type.
