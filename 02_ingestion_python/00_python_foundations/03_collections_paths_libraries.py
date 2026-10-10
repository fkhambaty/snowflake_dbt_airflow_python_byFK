"""Lists, dictionaries, imports, paths, exceptions, and command-line arguments."""

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--table", default="transactions")
    parser.add_argument("--limit", type=int, default=3)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    project_root = Path(__file__).resolve().parents[2]
    settings = {"table": args.table, "limit": args.limit, "root": project_root}
    rows = [
        {"transaction_id": 101, "amount": 25.50},
        {"transaction_id": 102, "amount": 14.00},
        {"transaction_id": 103, "amount": 61.25},
    ]

    try:
        print("Settings:", settings)
        for row in rows[: args.limit]:
            print(row["transaction_id"], "→", row["amount"])
    except (KeyError, TypeError) as exc:
        print("The row did not have the shape we expected:", exc)
        raise
    finally:
        print("A finally block runs whether the work passed or failed.")

    print("Libraries are reusable toolboxes:")
    print("pandas = tables in memory; pyarrow = typed Parquet; connectors = database cables")


if __name__ == "__main__":
    main()
