"""Offline checks for the student setup path."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "setup" / "start_postgres.py"
SPEC = importlib.util.spec_from_file_location("start_postgres", MODULE_PATH)
assert SPEC and SPEC.loader
start_postgres = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(start_postgres)


def test_every_automated_postgres_script_exists():
    assert all(
        (ROOT / "01_source_postgres" / filename).is_file()
        for filename in start_postgres.SQL_ORDER
    )


def test_database_script_order_keeps_card_triggers_after_card_tables():
    order = start_postgres.SQL_ORDER

    assert order.index("07_ddl_cards.sql") < order.index("04_cdc_triggers.sql")
    assert order.index("04_cdc_triggers.sql") < order.index("08_seed_cards.sql")
    assert order.index("08_seed_cards.sql") < order.index("09_card_simulator.sql")


def test_setup_readme_names_both_supported_commands():
    guide = (ROOT / "setup" / "README.md").read_text()

    assert "python3 setup/start_postgres.py" in guide
    assert r"py -3.12 setup\start_postgres.py" in guide
