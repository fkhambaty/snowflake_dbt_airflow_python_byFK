# Meridian Bank — Kimball Enterprise Bus Matrix

Rows = business processes (each becomes a fact table). Columns = conformed dimensions
(each built once, shared by every fact). An `X` means "this process is described by this dimension".

| Business process (fact) | Fact type | Grain | Date | Customer | Account | Branch | Product | Channel | Currency | Txn Type | Employee | Merchant | Sale event |
|---|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Account transactions → `fct_transactions` | Transaction | 1 row per transaction | X | X (PIT) | X (PIT) | X | X | X | X | X | X | | |
| Month-end balances → `fct_monthly_account_balance` | Periodic snapshot | 1 row per account per month-end | X | via bridge | X | X | X | | X | | | | |
| Loan application pipeline → `fct_loan_applications` | Accumulating snapshot | 1 row per application (updated in place) | X ×6 | X (PIT) | | X | X | | X | | X (officer) | | |
| Card authorizations → `fct_card_authorizations` | Transaction | 1 row per authorization | X | X (PIT) | | X | X | | X | | | X | X |
| Card applications → `fct_card_applications` | Accumulating snapshot | 1 row per application, features frozen at apply time | X | X (PIT) | | X | X | | X | | | | |
| Next-best offer → `fct_next_best_offer` | Accumulating (decision) | 1 recommended offer per customer | | X (current) | | | | | | | | | X |
| FX rates → `fct_fx_rates_daily` | Daily rate (factless-ish) | 1 row per day per currency | X | | | | | | X | | | | |
| Branch daily performance → `agg_branch_daily_performance` | Aggregate | 1 row per branch per day per currency | X | | | X | | | X | | | | |

PIT = point-in-time surrogate key into an SCD Type 2 dimension.

## Conformed dimensions

| Dimension | SCD type | Source of truth | Notes |
|---|---|---|---|
| `dim_date` | n/a (generated) | dbt `date_spine` | int `yyyymmdd` key; fiscal year Apr–Mar |
| `dim_customer` | **Type 2** | `snap_customers` (timestamp strategy) | segment, kyc, risk, home branch tracked; first version backdated to 1900 |
| `dim_account` | **Type 2** | `snap_accounts` (check strategy) | balance excluded on purpose; product attrs denormalised |
| `dim_branch` | Type 1 | `stg_postgres__branches` | history parked in `snap_branches` |
| `dim_product` | Type 1 | `stg_postgres__products` | |
| `dim_channel` | Type 1 | `stg_postgres__channels` | digital vs physical |
| `dim_currency` | Type 1 | `stg_postgres__currencies` | flags the reporting currency |
| `dim_transaction_type` | Junk | seed × status list | type × status = 30 rows |
| `dim_employee` | Type 1 | `stg_postgres__employees` | only branch-counter txns carry one |
| `dim_merchant` | Type 1 | `stg_postgres__merchants` | Flipkart and Amazon are merchants with a marketplace flag, not separate facts |
| `dim_card` | Type 1 | `stg_postgres__credit_cards` | last-4 only; no full PAN |
| `dim_sale_event` | Type 1 | `stg_postgres__sale_events` | published sale windows used to time offers |
| `dim_offer` | Type 1 | `stg_postgres__offer_catalog` | the catalogue; `fct_next_best_offer` picks one row per customer |
| `bridge_account_customer` | Bridge | `stg_postgres__account_holders` | many-to-many with weighting factor |

## Grain statements (say them out loud before writing any SQL)

- *"One row in `fct_transactions` is one money movement on one account, at its latest known status."*
- *"One row in `fct_monthly_account_balance` is the closing position of one account on one month-end."*
- *"One row in `fct_loan_applications` is one application, and the row changes as the application progresses."*

## Currency rules

1. Facts carry **local amount + reporting-currency amount + the rate used** (Kimball multi-currency pattern).
2. Flows (transactions) convert at the **transaction-date** rate; stocks (balances) at the **period-end** rate.
3. Rates are forward-filled over non-business days (`int_fx_rates_daily_filled`); the fill is flagged.
4. Changing the reporting currency is one variable (`reporting_currency`) and a `--full-refresh`.

## What is not a row on this matrix

`omni_search` is a serving index: one row per identifier, so a person can type part of a transaction id and land on the transaction, the account, the customer or the card authorization. It is not a business process. Putting it on the bus matrix would pretend the business asked for a new fact, when they asked for a way to find a row that already exists. See `00_architecture/adr/0009`.
