"""Offline checks for mart integrity, country security, and slow-query triage."""

from __future__ import annotations

import ast
from io import StringIO
from pathlib import Path

from snowflake.connector.util_text import split_statements

ROOT = Path(__file__).resolve().parents[1]


def _read(relative: str) -> str:
    return (ROOT / relative).read_text()


def _statements(relative: str) -> list[str]:
    text = _read(relative)
    statements = []
    for statement, _is_put in split_statements(StringIO(text), remove_comments=False):
        stripped = statement.strip()
        if stripped:
            statements.append(stripped)
    return statements


def _executable_text(statement: str) -> str:
    kept = []
    for line in statement.splitlines():
        if line.strip().startswith("--"):
            continue
        kept.append(line)
    return "\n".join(kept).strip()


def test_integrity_sql_is_executable_and_covers_the_lab():
    relative = "03_snowflake/11_mart_integrity_and_quarantine.sql"
    text = _read(relative)
    statements = _statements(relative)

    assert statements
    assert all(statement.count("$$") % 2 == 0 for statement in statements)
    assert any(_executable_text(statement) for statement in statements)
    assert "informational" in text
    assert "NOT NULL" in text
    assert "enforced" in text.lower()
    assert "DUPLICATE_BUSINESS_KEY" in text
    assert "ORPHAN_FACT" in text
    assert "UNKNOWN_MEMBER" in text
    assert "MART_QUARANTINE" in text
    assert "REVOKE INSERT, UPDATE, DELETE, TRUNCATE" in text
    assert "MERIDIAN_TRANSFORMER" in text

    raise_statements = [statement for statement in statements if "RAISE STATEMENT_ERROR" in statement]
    assert any("mart integrity violations" in statement for statement in raise_statements)
    assert any(
        "MART" in statement and "INSERT INTO" not in statement
        for statement in raise_statements
    )


def test_daily_dag_runs_integrity_after_build_and_before_reconcile():
    source = _read("05_airflow/dags/meridian_daily_batch.py")
    tree = ast.parse(source)

    assert "11_mart_integrity_and_quarantine.sql" in source
    assert "daily_extracts >> snapshots >> built >> checked >> reconciled >> docs >> manifest" in source
    assert "@task.bash(retries=0)" in source
    assert "def mart_integrity" in source

    class _ImportVisitor(ast.NodeVisitor):
        def __init__(self) -> None:
            self.depth = 0
            self.inline: list[int] = []

        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            self.depth += 1
            self.generic_visit(node)
            self.depth -= 1

        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            self.visit_FunctionDef(node)

        def visit_Import(self, node: ast.Import) -> None:
            if self.depth:
                self.inline.append(node.lineno)

        def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
            if self.depth:
                self.inline.append(node.lineno)

    visitor = _ImportVisitor()
    visitor.visit(tree)
    assert visitor.inline == []


def test_country_security_keeps_branch_personas_and_proves_hk():
    text = _read("03_snowflake/06_row_level_security.sql")
    head, country = text.split("-- COUNTRY ENTITLEMENT", 1)

    assert "RAP_CUSTOMER_SCOPE" in head
    assert "RAP_BRANCH_SCOPE" in head
    assert "RAP_BRANCH_INTERNAL" in head
    assert "BRANCH_MANAGER" in head
    assert "COUNTRY_OFFICER" not in head
    assert "persona IN ('STAFF', 'COUNTRY_STAFF')" in head

    assert "RAP_COUNTRY_SCOPE" in country
    assert "MERIDIAN_HK_OFFICER" in country
    assert "COUNTRY_OFFICER" in country
    assert "MERIDIAN_UNENTITLED" in country
    assert "ELSE FALSE" in country
    assert "MERIDIAN_RAW" in country
    assert "DIM_BRANCH" in country
    assert "DIM_CUSTOMER" in country
    assert "DIM_MERCHANT" in country
    assert "DIM_SALE_EVENT" in country
    assert "country_code" in country
    assert "MASK_PII_STRING" in country

    statements = _statements("03_snowflake/06_row_level_security.sql")
    assert statements
    assert all(statement.count("$$") % 2 == 0 for statement in statements)


def test_slow_query_playbook_follows_the_triage_order():
    text = _read("06_performance_lab/10_slow_query_triage_playbook.sql")
    statements = _statements("06_performance_lab/10_slow_query_triage_playbook.sql")

    assert statements
    assert all(statement.count("$$") % 2 == 0 for statement in statements)
    assert "USE_CACHED_RESULT = FALSE" in text
    assert "QUERY_HISTORY" in text
    assert "ORDER BY total_elapsed_time DESC" in text
    assert "ORDER BY total_elapsed_time ASC" in text
    assert "queued_overload_time" in text
    assert "execution_time" in text
    assert "GET_QUERY_OPERATOR_STATS" in text
    assert "input_rows" in text
    assert "output_rows" in text
    assert "partitions_scanned" in text
    assert "bytes_spilled" in text
    assert "Scale out" in text
    assert "Scale up" in text
    assert "perflab_10_fast" in text
    assert "perflab_10_slow" in text
    assert text.index("perflab_10_fast") < text.index("perflab_10_slow")
    assert text.index("USE_CACHED_RESULT = FALSE") < text.index("perflab_10_fast")


def test_multitenancy_adr_is_indexed():
    adr = _read("00_architecture/adr/0011-multitenancy-patterns.md")
    index = _read("00_architecture/adr/README.md")

    assert "Status:** Accepted" in adr
    assert "Shared tables" in adr
    assert "Schema per tenant" in adr
    assert "Database per tenant" in adr
    assert "UUID" in adr
    assert "row access policy" in adr.lower()
    assert "informational" in adr
    assert "NOT NULL" in adr
    assert "0011-multitenancy-patterns.md" in index


def test_dbt_integrity_test_matches_the_mart_rules():
    text = _read("04_dbt_meridian_dw/tests/assert_mart_referential_integrity.sql")

    assert "ref('fct_transactions')" in text
    assert "ref('dim_account')" in text
    assert "ref('dim_customer')" in text
    assert "ref('dim_branch')" in text
    assert "DUPLICATE_BUSINESS_KEY" in text
    assert "ORPHAN_FACT" in text
    assert "UNKNOWN_MEMBER_MISSING" in text
    assert "'-1'" in text
    assert "informational" in text
    assert "NOT NULL" in text
    assert "customer_id <> -1" in text
