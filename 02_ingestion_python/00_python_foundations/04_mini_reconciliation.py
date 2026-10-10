"""A tiny, dependency-free version of Meridian's reconciliation idea."""


def reconcile(
    source: dict[tuple[str, str], tuple[int, float]],
    warehouse: dict[tuple[str, str], tuple[int, float]],
    tolerance: float = 0.001,
) -> list[dict[str, object]]:
    """Compare count and amount by (date, currency); return every mismatch."""
    mismatches = []
    for key in sorted(source.keys() | warehouse.keys()):
        source_count, source_amount = source.get(key, (0, 0.0))
        warehouse_count, warehouse_amount = warehouse.get(key, (0, 0.0))
        amount_base = max(abs(source_amount), 1.0)
        amount_ratio = abs(source_amount - warehouse_amount) / amount_base
        if source_count != warehouse_count or amount_ratio > tolerance:
            mismatches.append(
                {
                    "date_currency": key,
                    "source_count": source_count,
                    "warehouse_count": warehouse_count,
                    "source_amount": source_amount,
                    "warehouse_amount": warehouse_amount,
                }
            )
    return mismatches


def main() -> int:
    source = {
        ("2026-10-09", "INR"): (100, 250_000.0),
        ("2026-10-09", "USD"): (20, 8_000.0),
    }
    warehouse = {
        ("2026-10-09", "INR"): (98, 247_500.0),
        ("2026-10-09", "USD"): (20, 8_000.0),
    }
    mismatches = reconcile(source, warehouse)
    if mismatches:
        print("FAILED: source and warehouse disagree")
        for mismatch in mismatches:
            print(mismatch)
        return 1
    print("PASSED: counts and amounts agree")
    return 0


if __name__ == "__main__":
    # A reconciliation failure is intentionally a non-zero process exit.
    # Airflow reads that exit code and marks its task failed.
    raise SystemExit(main())
