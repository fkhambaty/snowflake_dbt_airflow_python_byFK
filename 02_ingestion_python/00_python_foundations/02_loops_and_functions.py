"""for, while, functions, return values, and a safe loop."""


def tables_to_load(all_tables: list[str], hot_only: bool) -> list[str]:
    """Return either every table or only the two tables on the five-minute path."""
    if hot_only:
        return [name for name in all_tables if name in {"transactions", "card_authorizations"}]
    return all_tables


def describe_batch(batch_number: int, table: str) -> str:
    return f"batch {batch_number}: loading {table}"


def main() -> None:
    tables = ["customers", "transactions", "card_authorizations"]

    for table in tables_to_load(tables, hot_only=True):
        print(describe_batch(1, table))

    # Meridian uses an endless loop only when --loop is supplied. This bounded version
    # shows the same shape without making a beginner stop the program manually.
    run_number = 1
    while run_number <= 3:
        print(f"micro-batch heartbeat {run_number}")
        run_number += 1


if __name__ == "__main__":
    main()
