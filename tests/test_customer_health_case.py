"""Executable contract for the AcmeCloud customer-health case."""

import sys
from pathlib import Path

import pytest

CASE_DIR = Path(__file__).resolve().parents[1] / "12_case_studies" / "customer_health"
sys.path.insert(0, str(CASE_DIR))

import run_case


def _num(value, places=4):
    if value is None:
        return None
    return round(float(value), places)


def _account(connection, snapshot_date, account_id):
    rows = run_case.fetch_dicts(
        connection,
        """
        SELECT *
        FROM mart_customer_success_health
        WHERE snapshot_date = CAST(? AS DATE)
          AND salesforce_account_id = ?
        """,
        [snapshot_date, account_id],
    )
    assert len(rows) == 1
    return rows[0]


@pytest.fixture
def warehouse():
    connection = run_case.connect()
    run_case.build_default(connection)
    return connection


def test_seeds_are_labelled_synthetic(warehouse):
    for table_name in run_case.SEED_TABLES:
        blank = warehouse.execute(
            f"""
            SELECT COUNT(*)
            FROM raw_{table_name}
            WHERE record_label IS NULL OR record_label <> 'SYNTHETIC'
            """
        ).fetchone()[0]
        total = warehouse.execute(f"SELECT COUNT(*) FROM raw_{table_name}").fetchone()[0]
        assert blank == 0
        assert total > 0


def test_grain_is_one_row_per_account_per_snapshot(warehouse):
    counts = run_case.fetch_dicts(
        warehouse,
        """
        SELECT
            COUNT(*) AS rows,
            COUNT(DISTINCT snapshot_date || '|' || salesforce_account_id) AS keys,
            COUNT(*) FILTER (WHERE snapshot_date = DATE '2026-09-01') AS september_rows,
            COUNT(*) FILTER (WHERE snapshot_date = DATE '2026-10-01') AS october_rows
        FROM fct_account_health_daily
        """,
    )[0]
    assert counts["rows"] == 9
    assert counts["keys"] == 9
    assert counts["september_rows"] == 4
    assert counts["october_rows"] == 5
    assert warehouse.execute("SELECT COUNT(*) FROM dq_grain_violations").fetchone()[0] == 0
    assert warehouse.execute("SELECT COUNT(*) FROM dq_accepted_range_violations").fetchone()[0] == 0
    assert warehouse.execute("SELECT COUNT(*) FROM dq_relationship_violations").fetchone()[0] == 0
    prospect = warehouse.execute(
        "SELECT COUNT(*) FROM fct_account_health_daily WHERE salesforce_account_id = 'SF-006'"
    ).fetchone()[0]
    assert prospect == 0


def test_shared_display_name_does_not_merge_accounts(warehouse):
    rows = run_case.fetch_dicts(
        warehouse,
        """
        SELECT salesforce_account_id, mrr_usd
        FROM mart_customer_success_health
        WHERE snapshot_date = DATE '2026-10-01'
          AND account_name = 'Northwind Labs'
        ORDER BY salesforce_account_id
        """,
    )
    assert [row["salesforce_account_id"] for row in rows] == ["SF-001", "SF-004"]
    assert [_num(row["mrr_usd"], 2) for row in rows] == [1000, 100]
    staged = _account(warehouse, "2026-10-01", "SF-001")
    assert staged["account_name"] == "Northwind Labs"
    assert staged["segment"] == "Mid-Market"
    assert warehouse.execute(
        """
        SELECT COUNT(*)
        FROM fct_account_health_daily
        WHERE account_name = 'Northwind Inc'
        """
    ).fetchone()[0] == 0


def test_deterministic_dedupe_keeps_the_latest_version(warehouse):
    assert warehouse.execute(
        "SELECT COUNT(*) FROM raw_salesforce_accounts WHERE salesforce_account_id = 'SF-001'"
    ).fetchone()[0] == 2
    assert warehouse.execute(
        "SELECT COUNT(*) FROM stg_salesforce__accounts WHERE salesforce_account_id = 'SF-001'"
    ).fetchone()[0] == 1
    assert warehouse.execute(
        "SELECT COUNT(*) FROM raw_product_events WHERE event_id = 'eA01_sep'"
    ).fetchone()[0] == 2
    assert warehouse.execute(
        "SELECT COUNT(*) FROM stg_product__events WHERE event_id = 'eA01_sep'"
    ).fetchone()[0] == 1
    ticket = run_case.fetch_dicts(
        warehouse,
        "SELECT severity, status FROM stg_zendesk__tickets WHERE ticket_id = 'tA1'",
    )[0]
    assert ticket["severity"] == "low"
    assert ticket["status"] == "solved"
    renewal = run_case.fetch_dicts(
        warehouse,
        "SELECT renewal_date FROM stg_salesforce__renewals WHERE salesforce_account_id = 'SF-001'",
    )[0]
    assert str(renewal["renewal_date"]) == "2027-06-01"


def test_october_contract(warehouse):
    northwind = _account(warehouse, "2026-10-01", "SF-001")
    brightline = _account(warehouse, "2026-10-01", "SF-002")
    newly = _account(warehouse, "2026-10-01", "SF-003")
    other_northwind = _account(warehouse, "2026-10-01", "SF-004")
    medium = _account(warehouse, "2026-10-01", "SF-005")

    assert _num(northwind["mrr_usd"], 2) == 1000
    assert _num(northwind["excluded_tax_usd"], 2) == 80
    assert _num(northwind["excluded_one_off_usd"], 2) == 500
    assert _num(northwind["excluded_refund_mrr_usd"], 2) == 200
    assert _num(northwind["excluded_failed_mrr_usd"], 2) == 0
    assert northwind["non_usd_fx_rate"] is None
    assert northwind["active_users"] == 8
    assert northwind["eligible_users"] == 10
    assert _num(northwind["activity_score"]) == 80
    assert northwind["features_used"] == 4
    assert northwind["features_entitled"] == 4
    assert _num(northwind["adoption_score"]) == 100
    assert northwind["ticket_count_90d"] == 1
    assert _num(northwind["support_burden_points"]) == 1
    assert _num(northwind["support_score"]) == 97.5
    assert northwind["csat_responses_90d"] == 4
    assert _num(northwind["csat_average_90d"]) == 4.75
    assert _num(northwind["csat_score"]) == 93.75
    assert _num(northwind["health_score"]) == 90.5
    assert northwind["risk_band"] == "Low"
    assert northwind["days_to_renewal"] == 243
    assert _num(northwind["renewal_urgency"], 1) == 0.5
    assert _num(northwind["priority_score"], 2) == 500
    assert northwind["renewal_quarter"] == "2027Q2"
    assert northwind["fx_policy"] == run_case.FX_POLICY
    assert northwind["health_score_version"] == "v1"
    assert northwind["business_timezone"] == "America/New_York"
    assert northwind["publish_status"] == "published"

    assert _num(brightline["mrr_usd"], 2) == 1100
    assert _num(brightline["non_usd_fx_rate"], 2) == 1.1
    assert _num(brightline["excluded_failed_mrr_usd"], 2) == 500
    assert brightline["active_users"] == 2
    assert brightline["eligible_users"] == 20
    assert _num(brightline["activity_score"]) == 10
    assert brightline["features_used"] == 1
    assert brightline["features_entitled"] == 5
    assert _num(brightline["adoption_score"]) == 20
    assert brightline["csat_responses_90d"] == 2
    assert brightline["csat_score"] is None
    assert _num(brightline["support_burden_points"]) == 36
    assert _num(brightline["support_burden_per_active_user"]) == 18
    assert _num(brightline["support_score"]) == 0
    assert _num(brightline["health_score"]) == 12.5
    assert brightline["risk_band"] == "High"
    assert brightline["days_to_renewal"] == 19
    assert _num(brightline["priority_score"], 2) == 9900

    assert newly["unknown_reason"] == "newly_onboarded"
    assert newly["account_age_days"] == 16
    assert newly["health_score"] is None
    assert newly["risk_band"] == "Unknown"
    assert _num(newly["mrr_usd"], 2) == 300
    assert _num(newly["priority_score"], 2) == 0
    assert newly["active_users"] == 1

    assert _num(other_northwind["health_score"]) == 90
    assert other_northwind["risk_band"] == "Low"
    assert _num(other_northwind["priority_score"], 2) == 200
    assert other_northwind["days_to_renewal"] == 75

    assert _num(medium["health_score"]) == 59
    assert medium["risk_band"] == "Medium"
    assert _num(medium["priority_score"], 2) == 1600
    assert medium["days_to_renewal"] == 45

    order = run_case.fetch_dicts(
        warehouse,
        """
        SELECT salesforce_account_id
        FROM mart_customer_success_health
        WHERE snapshot_date = DATE '2026-10-01'
        ORDER BY priority_score DESC, salesforce_account_id
        """,
    )
    assert [row["salesforce_account_id"] for row in order] == [
        "SF-002",
        "SF-005",
        "SF-001",
        "SF-004",
        "SF-003",
    ]
    october_mrr = warehouse.execute(
        """
        SELECT SUM(mrr_usd)
        FROM fct_account_health_daily
        WHERE snapshot_date = DATE '2026-10-01'
        """
    ).fetchone()[0]
    assert _num(october_mrr, 2) == 2900


def test_september_windows_change_age_csat_and_activity(warehouse):
    northwind = _account(warehouse, "2026-09-01", "SF-001")
    brightline = _account(warehouse, "2026-09-01", "SF-002")
    medium = _account(warehouse, "2026-09-01", "SF-005")
    missing = warehouse.execute(
        """
        SELECT COUNT(*)
        FROM fct_account_health_daily
        WHERE snapshot_date = DATE '2026-09-01'
          AND salesforce_account_id = 'SF-003'
        """
    ).fetchone()[0]

    assert missing == 0
    assert northwind["active_users"] == 9
    assert _num(northwind["activity_score"]) == 90
    assert northwind["csat_responses_90d"] == 3
    assert _num(northwind["csat_score"]) == 91.6667
    assert _num(northwind["support_score"]) == 97.7778
    assert _num(northwind["health_score"]) == 94.1111
    assert _num(northwind["excluded_tax_usd"], 2) == 0
    assert _num(northwind["excluded_one_off_usd"], 2) == 0
    assert _num(northwind["excluded_refund_mrr_usd"], 2) == 200
    assert _num(northwind["mrr_usd"], 2) == 1000
    assert northwind["mrr_change_usd"] is None

    october = _account(warehouse, "2026-10-01", "SF-001")
    assert _num(october["mrr_change_usd"], 2) == 0
    newly = _account(warehouse, "2026-10-01", "SF-003")
    assert newly["mrr_change_usd"] is None

    assert _num(brightline["support_burden_points"]) == 23
    assert _num(brightline["health_score"]) == 12.5
    assert brightline["risk_band"] == "High"
    assert _num(brightline["mrr_usd"], 2) == 1100
    assert _num(medium["health_score"]) == 59
    assert medium["risk_band"] == "Medium"

    september_mrr = warehouse.execute(
        """
        SELECT SUM(mrr_usd)
        FROM fct_account_health_daily
        WHERE snapshot_date = DATE '2026-09-01'
        """
    ).fetchone()[0]
    assert _num(september_mrr, 2) == 2600


def test_timezone_boundary_and_exclusions(warehouse):
    october = run_case.fetch_dicts(
        warehouse,
        """
        SELECT user_id, is_eligible, has_qualifying_event, is_active, exclusion_reason
        FROM int_user_activity
        WHERE user_id IN ('uA09', 'uA10', 'uA_bot', 'uA_internal', 'uA_domain')
        ORDER BY user_id
        """,
    )
    by_user = {row["user_id"]: row for row in october}
    assert by_user["uA09"]["is_active"] is False
    assert by_user["uA10"]["is_active"] is False
    assert by_user["uA_bot"]["has_qualifying_event"] is True
    assert by_user["uA_bot"]["is_active"] is False
    assert by_user["uA_bot"]["exclusion_reason"] == "bot"
    assert by_user["uA_internal"]["exclusion_reason"] == "internal_user"
    assert by_user["uA_internal"]["is_active"] is False
    assert by_user["uA_domain"]["exclusion_reason"] == "internal_domain"
    assert by_user["uA_domain"]["is_active"] is False

    run_case.set_run(warehouse, "2026-09-01", "2026-09-02 06:00:00")
    september = run_case.fetch_dicts(
        warehouse,
        """
        SELECT is_active
        FROM int_user_activity
        WHERE user_id = 'uA09'
        """,
    )[0]
    assert september["is_active"] is True


def test_late_data_enters_only_after_as_of_moves():
    connection = run_case.connect()
    run_case.build_snapshot(connection, "2026-10-01", "2026-10-02 06:00:00")
    early = _account(connection, "2026-10-01", "SF-001")
    run_case.build_snapshot(connection, "2026-10-01", "2026-10-03 00:00:00")
    late = _account(connection, "2026-10-01", "SF-001")
    run_case.build_snapshot(connection, "2026-10-01", "2026-10-02 06:00:00")
    restored = _account(connection, "2026-10-01", "SF-001")

    assert early["active_users"] == 8
    assert str(early["as_of_timestamp"]).startswith("2026-10-02 06:00:00")
    assert late["active_users"] == 9
    assert _num(late["activity_score"]) == 90
    assert late["publish_status"] == "published"
    assert restored["active_users"] == 8
    assert connection.execute(
        "SELECT COUNT(*) FROM fct_account_health_daily WHERE snapshot_date = DATE '2026-10-01'"
    ).fetchone()[0] == 5


def test_stale_commercial_extract_is_labelled():
    connection = run_case.connect()
    run_case.build_snapshot(connection, "2026-10-01", "2026-10-10 00:00:00")
    row = _account(connection, "2026-10-01", "SF-001")
    assert row["publish_status"] == "stale_hold"
    assert row["health_score"] is not None
    assert str(row["as_of_timestamp"]).startswith("2026-10-10")


def test_rebuild_is_idempotent():
    connection = run_case.connect()
    run_case.build_default(connection)
    first = run_case.fetch_dicts(
        connection,
        """
        SELECT *
        FROM fct_account_health_daily
        ORDER BY snapshot_date, salesforce_account_id
        """,
    )
    run_case.build_default(connection)
    second = run_case.fetch_dicts(
        connection,
        """
        SELECT *
        FROM fct_account_health_daily
        ORDER BY snapshot_date, salesforce_account_id
        """,
    )
    assert first == second


def test_reconciliation_and_unmapped_sources(warehouse):
    october = run_case.fetch_dicts(warehouse, "SELECT * FROM recon_mrr")[0]
    assert _num(october["mart_mrr_usd"], 2) == 2900
    assert _num(october["subscription_mrr_usd"], 2) == 2900
    accounts = run_case.fetch_dicts(warehouse, "SELECT * FROM recon_accounts")[0]
    assert accounts["mart_accounts"] == accounts["source_customer_accounts"] == 5

    run_case.set_run(warehouse, "2026-09-01", "2026-09-02 06:00:00")
    september = run_case.fetch_dicts(warehouse, "SELECT * FROM recon_mrr")[0]
    assert _num(september["mart_mrr_usd"], 2) == 2600
    assert _num(september["subscription_mrr_usd"], 2) == 2600

    exceptions = run_case.fetch_dicts(
        warehouse,
        """
        SELECT source_system, source_account_id, unrecognized_mrr_usd
        FROM recon_exceptions
        ORDER BY source_system, source_account_id
        """,
    )
    assert [(row["source_system"], row["source_account_id"]) for row in exceptions] == [
        ("product", "prod_UNMAPPED"),
        ("stripe", "cus_ORPHAN"),
    ]
    orphan = next(row for row in exceptions if row["source_account_id"] == "cus_ORPHAN")
    assert _num(orphan["unrecognized_mrr_usd"], 2) == 999
    assert warehouse.execute(
        """
        SELECT COUNT(*)
        FROM fct_account_health_daily
        WHERE salesforce_account_id IN ('cus_ORPHAN', 'prod_UNMAPPED')
        """
    ).fetchone()[0] == 0


def test_backtest_withholds_automated_outreach(warehouse):
    backtest = run_case.fetch_dicts(warehouse, "SELECT * FROM backtest_high_risk")[0]
    gate = run_case.fetch_dicts(warehouse, "SELECT * FROM score_release_gate")[0]
    drift = run_case.fetch_dicts(
        warehouse,
        "SELECT * FROM dq_activity_drift WHERE salesforce_account_id = 'SF-001'",
    )[0]
    assert backtest["true_positive"] == 1
    assert backtest["false_positive"] == 0
    assert backtest["false_negative"] == 1
    assert _num(backtest["precision"], 2) == 1
    assert _num(backtest["recall"], 2) == 0.5
    assert gate["release_decision"] == "withhold_automated_outreach"
    assert _num(drift["activity_sep"]) == 90
    assert _num(drift["activity_oct"]) == 80


def test_mart_masks_email_and_exposes_csm_filter(warehouse):
    columns = [row[0] for row in warehouse.execute("DESCRIBE fct_account_health_daily").fetchall()]
    assert "csm_email_masked" in columns
    assert "csm_email" not in columns
    assert "email" not in columns
    masked = warehouse.execute(
        "SELECT DISTINCT csm_email_masked FROM fct_account_health_daily"
    ).fetchall()
    assert masked == [("***@acmecloud.example",)]
    staged = warehouse.execute(
        """
        SELECT csm_email
        FROM stg_salesforce__accounts
        WHERE salesforce_account_id = 'SF-001'
        """
    ).fetchone()[0]
    assert staged == "casey.morgan@acmecloud.example"
    priya = run_case.fetch_dicts(
        warehouse,
        """
        SELECT salesforce_account_id
        FROM mart_customer_success_health
        WHERE snapshot_date = DATE '2026-10-01'
          AND csm_name = 'Priya Shah'
        ORDER BY salesforce_account_id
        """,
    )
    assert [row["salesforce_account_id"] for row in priya] == ["SF-002", "SF-003"]
    europe = run_case.fetch_dicts(
        warehouse,
        """
        SELECT salesforce_account_id
        FROM mart_customer_success_health
        WHERE snapshot_date = DATE '2026-10-01'
          AND region = 'EU'
        """,
    )
    assert [row["salesforce_account_id"] for row in europe] == ["SF-003"]


def test_sql_does_not_join_on_display_name():
    sql_text = "\n".join(path.read_text(encoding="utf-8").lower() for path in (run_case.SQL_DIR.glob("*.sql")))
    assert "salesforce_account_id" in sql_text
    assert "account_name =" not in sql_text
    assert "using (account_name)" not in sql_text
