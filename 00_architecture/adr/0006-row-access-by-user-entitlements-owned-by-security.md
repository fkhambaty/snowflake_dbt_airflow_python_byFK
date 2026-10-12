# 0006. Row access keyed on the user; entitlements owned by security

**Status:** Accepted

## Context
A customer, a branch employee, a branch manager and the CEO use the same app and the
same semantic view. Each must see only their rows. Staff must not see contact details
or income.

## Decision
* Snowflake **row access policies** on the marts. They look up `CURRENT_USER()` in
  `MERIDIAN_ANALYTICS.GOVERNANCE.APP_USER` (persona, branch, customer).
* **Deny by default.** An unmapped user sees nothing. Only the engineering roles
  (`MERIDIAN_TRANSFORMER`, `MERIDIAN_ANALYST`, `MERIDIAN_ML`) bypass, through `IS_ROLE_IN_SESSION`.
* **Tag-based masking.** A column tagged `GOVERNANCE.PII` is masked for the staff persona.
* Security owns the policies, the tag and `APP_USER`. dbt only **attaches** them, from
  each model's `meta.governance`, in a post-hook (`APPLY` privilege, no ownership).

## Why key on the user and not the role
Streamlit in Snowflake runs with its **owner's** role, so `CURRENT_ROLE()` is the same for
every viewer. `CURRENT_USER()` is the viewer. Keying on the user also works for BI tools
with SSO.

## Alternatives
| Option | Why not |
|---|---|
| One secure view per persona | Four copies of every query. They drift, and the semantic view would need four versions. |
| Filtering in the app (`WHERE branch_id = ...`) | Any SQL path that bypasses the app bypasses the control. The LLM can also be prompted to drop the filter. |
| A role per branch (520 roles) | Role explosion. Moving a manager requires a grant change instead of a row update. |

## Consequences
* `CREATE OR REPLACE` drops policies. The post-hook re-attaches them on every build. If
  security has not installed governance yet, the hook warns, and the mart has no persona
  grants, so access fails closed.
* Policy bodies are changed with `ALTER ROW ACCESS POLICY ... SET BODY`, never replaced,
  because a policy cannot be replaced while attached.
* Every read is auditable through `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY`.
* Customers have **no grant** on branch-internal tables (employees, aggregates). A policy
  is not a substitute for a missing grant.
