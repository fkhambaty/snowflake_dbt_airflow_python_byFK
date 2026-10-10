"""Offline proofs for the source-to-warehouse reconciliation contract."""

from datetime import date, timedelta

import pandas as pd

import reconcile_with_pandas as reconciliation


def test_reconcile_requires_exact_row_count():
    source = pd.DataFrame(
        {
            "txn_date": [date(2026, 10, 9)],
            "grp": ["INR"],
            "src_rows": [100],
            "src_posted_amount": [250_000.00],
            "src_max_ts": [pd.Timestamp("2026-10-09T12:00:00")],
        }
    )
    warehouse = pd.DataFrame(
        {
            "txn_date": [date(2026, 10, 9)],
            "grp": ["INR"],
            "wh_rows": [99],
            "wh_posted_amount": [250_000.00],
            "wh_max_ts": [pd.Timestamp("2026-10-09T12:00:00")],
        }
    )

    result = reconciliation.reconcile(source, warehouse)

    assert result.loc[0, "row_diff"] == -1
    assert not bool(result.loc[0, "ok"])


def test_main_passes_one_cutoff_to_both_systems(monkeypatch):
    calls = {}
    timestamp = pd.Timestamp("2026-10-09T12:00:00")

    def source_frame(window_start, cutoff, by):
        calls["source"] = (window_start, cutoff, by)
        return pd.DataFrame(
            {
                "txn_date": [date(2026, 10, 9)],
                "grp": ["INR"],
                "src_rows": [100],
                "src_posted_amount": [250_000.00],
                "src_max_ts": [timestamp],
            }
        )

    def warehouse_frame(window_start, cutoff, by):
        calls["warehouse"] = (window_start, cutoff, by)
        return pd.DataFrame(
            {
                "txn_date": [date(2026, 10, 9)],
                "grp": ["INR"],
                "wh_rows": [100],
                "wh_posted_amount": [250_000.00],
                "wh_max_ts": [timestamp],
            }
        )

    monkeypatch.setattr(reconciliation, "source_frame", source_frame)
    monkeypatch.setattr(reconciliation, "warehouse_frame", warehouse_frame)

    assert reconciliation.main(["--days", "7", "--by", "currency"]) == 0
    assert calls["source"] == calls["warehouse"]

    window_start, cutoff, grouped_by = calls["source"]
    assert window_start == cutoff.date() - timedelta(days=6)
    assert grouped_by == "currency"
