# Asking the gold layer in English

The warehouse already defines the metrics. A chat box that writes its own SQL from table names will eventually sum a balance across months or join the wrong customer version. The semantic view is the contract: which tables, which joins, which metrics, and a handful of questions a human has already checked.

## What is feasible

| Idea | Where it lives | Honest limit |
|---|---|---|
| Approve / reject from years of history | `fct_card_applications` + `train_and_score.py` | Synthetic policy, no credit bureau, no regulatory model pack. The SQL policy is the decision of record; the model is a score next to it. |
| Market cards around Flipkart and Amazon sales | `ref.sale_events`, `fct_card_authorizations.marketplace`, `fct_next_best_offer` | We do not have Flipkart's or Amazon's shoppers. Offers use **our** cardholders' spend at those merchants and a published sale calendar. |
| Fraud prevention | Rules on `fct_card_authorizations`, queue `fct_card_fraud_alerts` | The label is injected so students can measure recall. It is not available at authorization time, and it is not a feature. |
| Upsell | `card_propensity_v1` score into `fct_next_best_offer` | Propensity is "looks like people we approved", not "will click a banner". |
| Plain English on the gold layer | Semantic view + Streamlit | Cortex Analyst is regional. The view and the verified SQL still work where chat does not. |
| Customer, staff, branch manager, CEO see different rows | `03_snowflake/06_row_level_security.sql` | The login is a Snowflake user. A password checked only inside Python would not stop a worksheet. Staff and the branch manager see the same rows; staff contact details and income are masked. |

## Order

1. `dbt build --target prod` so the marts exist in `MERIDIAN_ANALYTICS.MARTS`.
2. Run `03_snowflake/06_row_level_security.sql` as `ACCOUNTADMIN`. It creates the `GOVERNANCE` schema, the `APP_USER` entitlement table, the policies, the PII tag, and four demo users. The final `SELECT` shows which branch and customer each demo user is mapped to.
3. Set each demo user's password in Snowsight (Admin → Users & Roles). The file contains no password. Each user must change it at first login.
4. `dbt run-operation apply_governance_all --target prod` attaches the policies and tags to the marts that already exist. After this, every `dbt build` re-attaches them through the post-hook.
5. Run `01_semantic_view.sql` as `MERIDIAN_TRANSFORMER`.
6. Either create the app in Snowsight with role **`MERIDIAN_APP`** (warehouse `WH_BI_XS`, paste `streamlit_app.py`, then `GRANT USAGE ON STREAMLIT ... TO ROLE` each persona), or run it on a laptop with `streamlit run 10_semantic_app/streamlit_app.py`.
7. Log in as each user, ask one of the four onboarding questions, and open the SQL expander. The SQL should be the same for everyone. The rows should not. Then open **Find an identifier**, type 4 digits from a transaction id, and compare the CEO's hits with the customer's. The search box does not have its own permission check. It reads `OMNI_SEARCH`, and the row policy on that table does the filtering.

Why the app owner is `MERIDIAN_APP` and not `MERIDIAN_TRANSFORMER`: Streamlit in Snowflake runs every query with its owner's role. The transformer role bypasses row policies, so an app owned by it would show every viewer the whole bank. `MERIDIAN_APP` is deliberately **not** a bypass role. The policy then decides from `CURRENT_USER()` (the viewer), and a viewer missing from `APP_USER` sees nothing.

Log out between users. `USE ROLE` does not change `CURRENT_USER()`, and the policy reads the user.

## If CREATE SEMANTIC VIEW fails

The feature is not enabled on that account. Run the same four questions from `04_dbt_meridian_dw/analyses/card_questions.sql` (`dbt compile`, paste into Snowsight). Do not demo a chat that has no semantic contract.

## If the chat returns a region error

Cortex Analyst runs in a subset of Snowflake regions (commonly AWS US and EU; confirm in the Cortex Analyst docs for the week you record). A trial in ap-south-1 can build every table in this project and still refuse the chat API. Two honest options: create the trial in a Cortex region, or show the verified SQL and say the app is the client. The app prints the platform error; it does not invent a number.
