#!/usr/bin/env python3
"""Promote or fetch dbt state from the Snowflake internal artifact stage."""
from __future__ import annotations

import argparse
import os
from pathlib import Path

from pg_to_snowflake import sf_connect

STAGE = "@MERIDIAN_RAW.CONTROL.DBT_ARTIFACTS/prod"


def connection():
    return sf_connect(
        user=os.getenv("SNOWFLAKE_DBT_USER", "MERIDIAN_DBT_SVC"),
        role="MERIDIAN_TRANSFORMER",
        warehouse=os.getenv("SNOWFLAKE_DBT_WAREHOUSE", "WH_TRANSFORM_XS"),
        query_tag="meridian_dbt_artifact",
    )


def upload(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(path)
    conn = connection()
    try:
        conn.cursor().execute(
            f"PUT file://{path.resolve()} {STAGE}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
        )
    finally:
        conn.close()


def download(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    conn = connection()
    try:
        conn.cursor().execute(
            f"GET {STAGE}/manifest.json file://{directory.resolve()}/"
        )
    finally:
        conn.close()
    if not (directory / "manifest.json").is_file():
        raise RuntimeError("manifest.json was not downloaded from the production artifact stage")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    put = sub.add_parser("upload")
    put.add_argument("path", type=Path)
    get = sub.add_parser("download")
    get.add_argument("directory", type=Path)
    args = parser.parse_args()
    upload(args.path) if args.command == "upload" else download(args.directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
