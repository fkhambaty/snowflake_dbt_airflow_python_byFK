"""Offline proof that the beginner reconciliation example behaves like a gate."""

import importlib.util
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "02_ingestion_python"
    / "00_python_foundations"
    / "04_mini_reconciliation.py"
)
SPEC = importlib.util.spec_from_file_location("mini_reconciliation", MODULE_PATH)
assert SPEC and SPEC.loader
mini_reconciliation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mini_reconciliation)


def test_reconcile_returns_no_mismatches_when_both_sides_agree():
    totals = {("2026-10-09", "USD"): (20, 8_000.0)}

    assert mini_reconciliation.reconcile(totals, totals) == []


def test_reconcile_reports_missing_rows():
    source = {("2026-10-09", "INR"): (100, 250_000.0)}
    warehouse = {("2026-10-09", "INR"): (98, 247_500.0)}

    mismatches = mini_reconciliation.reconcile(source, warehouse)

    assert mismatches[0]["source_count"] == 100
    assert mismatches[0]["warehouse_count"] == 98
