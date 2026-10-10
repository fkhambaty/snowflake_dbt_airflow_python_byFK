"""The extractor's pure logic: type mapping, timezone normalisation, table registry."""
from collections import namedtuple
from datetime import datetime, timezone
from types import SimpleNamespace

import pandas as pd
import pyarrow as pa
import pytest

from config import TABLES
import pg_to_snowflake as extractor
from pg_to_snowflake import (
    build_arrow_schema,
    normalise_dataframe,
    parse_utc_timestamp,
    replay_window,
    should_advance_watermark,
)

Column = namedtuple("Column", "name type_code")


def test_unknown_postgres_type_becomes_string_not_dropped():
    schema = build_arrow_schema([Column("weird", 999_999)], {})
    assert schema.field("weird").type == pa.string()


def test_numeric_stays_decimal_not_float():
    schema = build_arrow_schema([Column("amount", 1700)], {})
    assert pa.types.is_decimal(schema.field("amount").type)


def test_timestamptz_is_normalised_to_naive_utc():
    df = pd.DataFrame({"updated_at": [pd.Timestamp("2026-10-01 10:00:00+05:30")]})
    out = normalise_dataframe(df, [Column("updated_at", 1184)])
    assert out["updated_at"].dt.tz is None
    assert out["updated_at"].iloc[0] == pd.Timestamp("2026-10-01 04:30:00")


def test_every_table_has_a_primary_key_and_a_cursor():
    for table in TABLES:
        assert table.primary_key, table.qualified_source
        assert table.cursor_column, table.qualified_source


def test_model_output_is_not_replicated_from_the_source():
    assert "core.ml_scores" not in {t.qualified_source for t in TABLES}


def test_replay_bounds_are_utc_and_do_not_advance_watermark():
    window = replay_window("2026-10-01T10:00:00+05:30", "2026-10-01T05:00:00Z")
    assert window == (
        datetime(2026, 10, 1, 4, 30, tzinfo=timezone.utc),
        datetime(2026, 10, 1, 5, 0, tzinfo=timezone.utc),
    )
    assert not should_advance_watermark(window)
    assert should_advance_watermark(None)


@pytest.mark.parametrize(
    ("since", "until"),
    [
        ("2026-10-01T00:00:00Z", None),
        (None, "2026-10-02T00:00:00Z"),
        ("2026-10-02T00:00:00Z", "2026-10-01T00:00:00Z"),
    ],
)
def test_replay_requires_two_ordered_bounds(since, until):
    with pytest.raises(ValueError):
        replay_window(since, until)


def test_replay_rejects_an_ambiguous_local_timestamp():
    with pytest.raises(ValueError, match="timezone required"):
        parse_utc_timestamp("2026-10-01T12:00:00")


def test_a_table_failure_makes_the_one_shot_job_fail(monkeypatch, tmp_path):
    closed = []
    monkeypatch.setattr(extractor, "INGEST", SimpleNamespace(local_dir=tmp_path))
    monkeypatch.setattr(extractor, "pg_connect", lambda: SimpleNamespace(close=lambda: closed.append("pg")))
    monkeypatch.setattr(extractor, "sf_connect", lambda: SimpleNamespace(close=lambda: closed.append("sf")))
    monkeypatch.setattr(extractor, "process_table", lambda *_args, **_kwargs: False)

    with pytest.raises(RuntimeError, match="core.transactions"):
        extractor.run_once([next(t for t in TABLES if t.qualified_source == "core.transactions")])
    assert closed == ["pg", "sf"]
