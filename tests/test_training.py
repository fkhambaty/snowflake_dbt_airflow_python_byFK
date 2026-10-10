"""Guards on the training job that must hold without a warehouse connection."""
import pandas as pd
import pytest

import train_and_score as t


@pytest.mark.parametrize("features", [t.DECISION_NUMERIC + t.DECISION_CATEGORICAL,
                                      t.PROPENSITY_NUMERIC + t.PROPENSITY_CATEGORICAL,
                                      t.FRAUD_NUMERIC])
def test_no_model_uses_the_label_or_a_rule_flag(features):
    t.assert_no_leakage(features)


def test_leakage_guard_rejects_the_fraud_label():
    with pytest.raises(ValueError, match="fraud_label"):
        t.design_matrix(pd.DataFrame({"fraud_label": [1], "amount": [1.0]}), ["amount", "fraud_label"], [])


def test_time_split_holds_out_the_most_recent_rows():
    df = pd.DataFrame({"ts": pd.date_range("2026-01-01", periods=100, freq="D")})
    train, test, label = t.time_split(df, "ts", holdout_days=10)
    assert df.loc[train, "ts"].max() < df.loc[test, "ts"].min()
    assert len(test) == 11
    assert label.startswith("TIME")


def test_score_bands():
    assert [t.band(s) for s in (0.1, 0.4, 0.69, 0.7)] == ["LOW", "MEDIUM", "MEDIUM", "HIGH"]


def test_a_model_below_the_gate_is_not_published():
    result = t.ModelResult("m", "CUSTOMER", pd.DataFrame(), 10, 10, t.AUC_GATE - 0.01, "TIME", [], "x")
    assert not result.passed
    assert not t.ModelResult("m", "CUSTOMER", pd.DataFrame(), 10, 10, float("nan"), "TIME", [], "x").passed
