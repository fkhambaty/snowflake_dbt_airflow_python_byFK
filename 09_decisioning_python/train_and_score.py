"""
Train the card models from the gold layer and land scores in Snowflake.

    python 09_decisioning_python/train_and_score.py            # train, gate, publish
    python 09_decisioning_python/train_and_score.py --dry-run  # train and report, write nothing

Why Python and not dbt? Fitting a model, holding out a time split and producing a
probability is not a SQL transform. dbt builds the features; this job learns from
them. Why read the warehouse and not Postgres? The features must be the same rows
that production scores (ml_customer_features, fct_card_authorizations), already
point-in-time correct, already conformed. Reading the OLTP would build a second,
different definition of every feature.

Data flow (no arrow points back into the source system):
    MARTS.fct_card_applications  ─┐
    MARTS.ml_customer_features   ─┼─> this job ─> MERIDIAN_RAW.ML.MODEL_RUNS / MODEL_SCORES
    MARTS.fct_card_authorizations ┘                 └─> dbt stg_ml__model_scores -> marts

A run whose holdout AUC is below the gate is recorded as REJECTED and its scores
are not written. The offer mart then falls back to the published policy (score_source = RULE).

Models (probability of the positive class):
  card_decision_v1         P(approve)                    entity APPLICATION
  card_propensity_v1       P(would be approved)          entity CUSTOMER
  card_fraud_v1            P(injected fraud pattern)     entity AUTHORIZATION
  card_fraud_customer_v1   max recent fraud probability  entity CUSTOMER
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import snowflake.connector
from cryptography.hazmat.primitives import serialization
from dotenv import load_dotenv
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.preprocessing import StandardScaler
from snowflake.connector.pandas_tools import write_pandas

load_dotenv(Path(__file__).resolve().parents[1] / ".env")

GOLD = os.getenv("MERIDIAN_GOLD_SCHEMA", "MERIDIAN_ANALYTICS.MARTS")
ML_SCHEMA = "MERIDIAN_RAW.ML"
AUC_GATE = float(os.getenv("MERIDIAN_AUC_GATE", "0.70"))

# Columns that must never be model inputs. The ground-truth label is the target of the
# fraud model; the rule flags are derived from the same features and would be circular.
FORBIDDEN_FEATURES = {"fraud_label", "fraud_pattern", "decision", "has_been_approved", "is_rule_suspect"}

DECISION_NUMERIC = [
    "income_at_apply", "balance_at_apply", "salary_credits_3m_at_apply",
    "tenure_months_at_apply", "age_years_at_apply",
]
DECISION_CATEGORICAL = ["segment_at_apply", "risk_rating_at_apply"]
PROPENSITY_NUMERIC = ["estimated_annual_income", "avg_monthly_balance", "salary_credits_3m", "tenure_months", "age_years"]
PROPENSITY_CATEGORICAL = ["segment", "risk_rating"]
FRAUD_NUMERIC = ["auths_in_10m", "amount_vs_prior", "amount_vs_limit", "country_mismatch", "card_present"]


@dataclass
class ModelResult:
    model_name: str
    entity_type: str
    scores: pd.DataFrame          # entity_id, score, explanation
    training_rows: int
    holdout_rows: int
    holdout_auc: float
    split_strategy: str
    features: list[str]
    feature_source: str

    @property
    def passed(self) -> bool:
        return self.holdout_auc == self.holdout_auc and self.holdout_auc >= AUC_GATE


# ----------------------------------------------------------------------------- pure helpers
def band(score: float) -> str:
    if score >= 0.70:
        return "HIGH"
    if score >= 0.40:
        return "MEDIUM"
    return "LOW"


def assert_no_leakage(features: list[str]) -> None:
    leaked = FORBIDDEN_FEATURES.intersection(features)
    if leaked:
        raise ValueError(f"label or label-derived columns used as features: {sorted(leaked)}")


def design_matrix(frame: pd.DataFrame, numeric: list[str], categorical: list[str]) -> pd.DataFrame:
    assert_no_leakage(numeric + categorical)
    parts = [frame[numeric].astype(float).fillna(0.0)]
    for col in categorical:
        parts.append(pd.get_dummies(frame[col].astype(str), prefix=col, dtype=float))
    return pd.concat(parts, axis=1)


def time_split(frame: pd.DataFrame, ts_col: str, holdout_days: int) -> tuple[pd.Index, pd.Index, str]:
    """Hold out the most recent window. A random split leaks the future into training."""
    cutoff = frame[ts_col].max() - pd.Timedelta(days=holdout_days)
    train = frame.index[frame[ts_col] < cutoff]
    test = frame.index[frame[ts_col] >= cutoff]
    return train, test, f"TIME holdout >= {cutoff:%Y-%m-%d}"


def fit_and_score(x: pd.DataFrame, y: pd.Series, train: pd.Index, test: pd.Index) -> tuple[pd.Series, float, list[tuple[str, float]]]:
    scaler = StandardScaler()
    model = LogisticRegression(max_iter=500, class_weight="balanced")
    model.fit(scaler.fit_transform(x.loc[train]), y.loc[train])
    auc = float("nan")
    if y.loc[test].nunique() > 1:
        auc = roc_auc_score(y.loc[test], model.predict_proba(scaler.transform(x.loc[test]))[:, 1])
    scores = pd.Series(model.predict_proba(scaler.transform(x))[:, 1], index=x.index)
    coefs = sorted(zip(x.columns, model.coef_[0]), key=lambda kv: abs(kv[1]), reverse=True)
    return scores, auc, coefs


# ----------------------------------------------------------------------------- Snowflake
def connect():
    kwargs = dict(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.getenv("SNOWFLAKE_ML_USER", os.getenv("SNOWFLAKE_USER", "")),
        role=os.getenv("SNOWFLAKE_ML_ROLE", "MERIDIAN_ML"),
        warehouse=os.getenv("SNOWFLAKE_ML_WAREHOUSE", "WH_TRANSFORM_XS"),
        session_parameters={"QUERY_TAG": "meridian_ml_training", "TIMEZONE": "UTC"},
    )
    key_path = os.getenv("SNOWFLAKE_ML_PRIVATE_KEY_PATH", os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", ""))
    if key_path:
        passphrase = os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "").encode() or None
        key = serialization.load_pem_private_key(Path(key_path).expanduser().read_bytes(), password=passphrase)
        kwargs["private_key"] = key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    else:
        kwargs["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    return snowflake.connector.connect(**kwargs)


def read(conn, sql: str) -> pd.DataFrame:
    cur = conn.cursor()
    try:
        cur.execute(sql)
        frame = cur.fetch_pandas_all()
    finally:
        cur.close()
    frame.columns = [c.lower() for c in frame.columns]
    return frame


def code_version() -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=Path(__file__).parent, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


# ----------------------------------------------------------------------------- models
def train_decision(conn) -> ModelResult | None:
    df = read(conn, f"""
        select application_id, decided_at, decision,
               {', '.join(DECISION_NUMERIC + DECISION_CATEGORICAL)}
        from {GOLD}.fct_card_applications
        where decision in ('APPROVED', 'REJECTED')
    """)
    if df.empty:
        print("card_decision_v1  no decided applications in the gold layer")
        return None
    df["decided_at"] = pd.to_datetime(df["decided_at"])
    y = (df["decision"] == "APPROVED").astype(int)
    x = design_matrix(df, DECISION_NUMERIC, DECISION_CATEGORICAL)
    train, test, split = time_split(df, "decided_at", holdout_days=60)
    scores, auc, coefs = fit_and_score(x, y, train, test)
    print(f"card_decision_v1  holdout AUC {auc:.3f}  train {len(train):,} / test {len(test):,}  approve rate {y.mean():.1%}")
    print("  largest |coefficients|:", ", ".join(f"{n}={c:+.2f}" for n, c in coefs[:6]))
    out = pd.DataFrame({
        "entity_id": df["application_id"],
        "score": scores,
        "explanation": scores.map(lambda p: f"P(approve)={p:.2f}; top drivers: " + ", ".join(n for n, _ in coefs[:3])),
    })
    return ModelResult("card_decision_v1", "APPLICATION", out, len(train), len(test), auc, split,
                       list(x.columns), f"{GOLD}.FCT_CARD_APPLICATIONS")


def train_propensity(conn) -> ModelResult | None:
    df = read(conn, f"""
        select customer_id, has_been_approved, has_active_card, feature_source,
               {', '.join(PROPENSITY_NUMERIC + PROPENSITY_CATEGORICAL)}
        from {GOLD}.ml_customer_features
    """)
    if df.empty:
        print("card_propensity_v1 no rows in ml_customer_features")
        return None
    y = df["has_been_approved"].astype(int)
    x = design_matrix(df, PROPENSITY_NUMERIC, PROPENSITY_CATEGORICAL)
    test = df.sample(frac=0.2, random_state=7).index
    train = df.index.difference(test)
    scores, auc, _ = fit_and_score(x, y, train, test)
    print(f"card_propensity_v1 holdout AUC {auc:.3f}  positive rate {y.mean():.1%}  "
          f"prospects without a card {(~df['has_active_card'].astype(bool)).sum():,}")
    print("  feature_source mix:", df["feature_source"].value_counts().to_dict())
    out = pd.DataFrame({
        "entity_id": df["customer_id"],
        "score": scores,
        "explanation": [f"P(approved for a card)={p:.2f}; has_active_card={bool(h)}"
                        for p, h in zip(scores, df["has_active_card"])],
    })
    return ModelResult("card_propensity_v1", "CUSTOMER", out, len(train), len(test), auc,
                       "RANDOM 20% (customers have no event time)", list(x.columns), f"{GOLD}.ML_CUSTOMER_FEATURES")


def score_fraud(conn) -> list[ModelResult]:
    """Rules are the control. The model shows a measured AUC next to them.

    fraud_label is the synthetic ground truth: the target, never a feature.
    A real bank measures this on confirmed chargebacks, which arrive weeks later.
    """
    df = read(conn, f"""
        select authorization_id, customer_id, card_id, auth_ts,
               amount_local, credit_limit, auths_in_10m, avg_prior_amount, card_present,
               iff(merchant_country <> customer_country, 1, 0) as country_mismatch,
               is_velocity, is_geo_mismatch, is_high_amount, is_card_testing, is_rule_suspect,
               fraud_label, fraud_pattern
        from {GOLD}.fct_card_authorizations
    """)
    if df.empty:
        print("card_fraud_v1     no authorizations")
        return []
    df["auth_ts"] = pd.to_datetime(df["auth_ts"])
    df["amount_vs_prior"] = df["amount_local"] / df["avg_prior_amount"].fillna(df["amount_local"]).clip(lower=1)
    df["amount_vs_limit"] = df["amount_local"] / df["credit_limit"].fillna(df["amount_local"]).clip(lower=1)
    df["card_present"] = df["card_present"].astype(int)

    labeled = df["fraud_label"].astype(bool)
    suspect = df["is_rule_suspect"].astype(bool)
    pattern_recall = df[labeled].groupby(["card_id", "fraud_pattern"], dropna=False)["is_rule_suspect"].max().mean()
    precision = df.loc[suspect, "fraud_label"].astype(bool).mean() if suspect.any() else float("nan")
    print(f"fraud rules       pattern recall {pattern_recall:.1%}  row recall {suspect[labeled].mean():.1%}  precision {precision:.1%}")

    y = labeled.astype(int)
    x = design_matrix(df, FRAUD_NUMERIC, [])
    train, test, split = time_split(df, "auth_ts", holdout_days=14)
    scores, auc, _ = fit_and_score(x, y, train, test)
    print(f"card_fraud_v1     holdout AUC {auc:.3f}  (features exclude fraud_label and rule flags)")

    rule_names = {"is_velocity": "velocity", "is_geo_mismatch": "geo", "is_high_amount": "amount", "is_card_testing": "testing"}
    fired = df[list(rule_names)].astype(bool)
    explanation = fired.apply(lambda r: "rules: " + (",".join(rule_names[c] for c in r.index if r[c]) or "none"), axis=1)
    auth = pd.DataFrame({"entity_id": df["authorization_id"], "score": scores, "explanation": explanation})

    recent = df.assign(score=scores).sort_values("auth_ts").groupby("customer_id").tail(20)
    customer = recent.groupby("customer_id", as_index=False)["score"].max()
    customer = pd.DataFrame({
        "entity_id": customer["customer_id"],
        "score": customer["score"],
        "explanation": customer["score"].map(lambda p: f"max of last 20 authorization fraud scores={p:.2f}"),
    })
    source = f"{GOLD}.FCT_CARD_AUTHORIZATIONS"
    return [
        ModelResult("card_fraud_v1", "AUTHORIZATION", auth, len(train), len(test), auc, split, list(x.columns), source),
        ModelResult("card_fraud_customer_v1", "CUSTOMER", customer, len(train), len(test), auc, split, list(x.columns), source),
    ]


def report_sale_uplift(conn) -> None:
    uplift = read(conn, f"""
        select marketplace,
               round(avg(iff(sale_event_name is not null, amount_local, null)), 0) as avg_in_sale,
               round(avg(iff(sale_event_name is null, amount_local, null)), 0)     as avg_outside,
               count_if(sale_event_name is not null)                               as auths_in_sale
        from {GOLD}.fct_card_authorizations
        where marketplace is not null and response = 'APPROVED'
        group by 1 order by 1
    """)
    print("marketplace spend per authorization, inside vs outside a published sale window:")
    for row in uplift.itertuples(index=False):
        lift = (row.avg_in_sale or 0) / (row.avg_outside or 1)
        print(f"  {row.marketplace:<10} in sale {row.avg_in_sale}  outside {row.avg_outside}  lift {lift:.2f}x  auths {row.auths_in_sale}")


# ----------------------------------------------------------------------------- publish
def publish(conn, results: list[ModelResult], dry_run: bool) -> None:
    version = code_version()
    trained_at = datetime.now(timezone.utc).replace(tzinfo=None)
    for result in results:
        run_id = uuid.uuid4().hex
        status = "SUCCEEDED" if result.passed else "REJECTED"
        print(f"{result.model_name:<24} {status}  AUC {result.holdout_auc:.3f} (gate {AUC_GATE:.2f})  {len(result.scores):,} scores")
        if dry_run:
            continue
        cur = conn.cursor()
        try:
            cur.execute(
                f"""
                insert into {ML_SCHEMA}.MODEL_RUNS
                    (run_id, model_name, entity_type, trained_at, training_rows, holdout_rows,
                     holdout_auc, split_strategy, features, feature_source, code_version, status)
                select %s, %s, %s, %s, %s, %s, %s, %s, parse_json(%s), %s, %s, %s
                """,
                (run_id, result.model_name, result.entity_type, trained_at, result.training_rows,
                 result.holdout_rows, None if result.holdout_auc != result.holdout_auc else result.holdout_auc,
                 result.split_strategy, json.dumps(result.features), result.feature_source, version, status),
            )
        finally:
            cur.close()
        if not result.passed:
            continue
        frame = result.scores.copy()
        frame["score"] = frame["score"].clip(0, 1).astype(float)
        frame = frame.assign(
            RUN_ID=run_id,
            MODEL_NAME=result.model_name,
            ENTITY_TYPE=result.entity_type,
            ENTITY_ID=frame["entity_id"].astype("int64"),
            SCORE=frame["score"],
            SCORE_BAND=frame["score"].map(band),
            EXPLANATION=frame["explanation"],
            SCORED_AT=trained_at,
        )[["RUN_ID", "MODEL_NAME", "ENTITY_TYPE", "ENTITY_ID", "SCORE", "SCORE_BAND", "EXPLANATION", "SCORED_AT"]]
        write_pandas(conn, frame, "MODEL_SCORES", database="MERIDIAN_RAW", schema="ML", use_logical_type=True)
    if not dry_run:
        conn.commit()
        print("next: dbt build -s stg_ml__model_scores+  (the weekly DAG does this)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="train and report, write nothing")
    args = parser.parse_args(argv)
    conn = connect()
    try:
        results: list[ModelResult] = []
        for trained in (train_decision(conn), train_propensity(conn)):
            if trained is not None:
                results.append(trained)
        results.extend(score_fraud(conn))
        report_sale_uplift(conn)
        publish(conn, results, args.dry_run)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
