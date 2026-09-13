"""
Feature I1 — export the risk model so it can run on the phone.

Writes, into the Flutter app:
  mobile/assets/ml/risk_model.json     every tree of the GradientBoosting
                                       ensemble + init score + tier table
  mobile/assets/ml/parity_vectors.json feature vectors and the scores sklearn
                                       gives them, for the Dart parity test

The full ensemble is exported rather than a distilled tree: 100 trees of depth
4 is ~3k nodes (~150 KB of JSON), and an exact port gives exact parity where a
distilled copy would only approximate it.

// PROD-TODO: replace the hand-port with an ONNX Runtime Mobile export.

Run from backend/:  .venv/bin/python -m scripts.export_model
"""
import json
import os
import sys

import joblib
import numpy as np
import sklearn

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BACKEND)

from app.config import MAX_OFFLINE_LIMIT, MIN_OFFLINE_LIMIT  # noqa: E402
from app.ml.train_model import generate_synthetic_data  # noqa: E402
from app.services.risk_engine import compute_offline_limit  # noqa: E402

MODEL_PATH = os.path.join(BACKEND, "ml_model", "risk_model.joblib")
OUT_DIR = os.path.join(os.path.dirname(BACKEND), "mobile", "assets", "ml")

FEATURES = [
    "transaction_count",
    "avg_transaction_amount",
    "kyc_tier",
    "device_trust_score",
    "days_since_registration",
    "fraud_flags",
    "total_spent",
]

# risk >= threshold -> limit, checked top-down. Mirrors compute_offline_limit;
# the self-check below fails the export if the two ever drift apart.
TIERS = [
    [0.9, 0.0],
    [0.8, float(MIN_OFFLINE_LIMIT)],
    [0.6, 500.0],
    [0.4, 1500.0],
    [0.2, 3000.0],
    [0.0, float(MAX_OFFLINE_LIMIT)],
]


def _vec(tx, avg, kyc, trust, days, fraud, total=None):
    return [tx, avg, kyc, trust, days, fraud, tx * avg if total is None else total]


# Named cases: the seeded demo cast plus deliberate tier-crossers, so the parity
# test exercises every branch that matters on stage — not just 0.0004s.
NAMED = {
    "ashmita (stage sender)": _vec(214, 340.0, 3, 0.95, 420, 0),
    "alice": _vec(45, 250.0, 3, 0.85, 200, 0),
    "bob": _vec(12, 150.0, 2, 0.65, 90, 0),
    "charlie (1 fraud flag)": _vec(3, 80.0, 1, 0.4, 20, 1),
    "attacker": _vec(0, 0.0, 0, 0.15, 1, 1, 0.0),
    "jyati (merchant)": _vec(180, 290.0, 3, 0.92, 365, 0),
    "shopkeeper (new merchant)": _vec(0, 0.0, 2, 0.7, 30, 0, 0.0),
    "ashmita + 2 fraud flags": _vec(214, 340.0, 3, 0.95, 420, 2),
    "attacker-ish, trust 0.5": _vec(0, 0.0, 0, 0.5, 1, 1, 0.0),
    "3 fraud flags": _vec(20, 500.0, 1, 0.3, 10, 3),
    "zeros": _vec(0, 0.0, 0, 0.0, 0, 0, 0.0),
}


def export_tree(estimator):
    t = estimator.tree_
    return {
        "left": t.children_left.tolist(),
        "right": t.children_right.tolist(),
        "feature": t.feature.tolist(),
        "threshold": [float(x) for x in t.threshold],
        "value": [float(v[0][0]) for v in t.value],
    }


def reference_proba(doc, x):
    """Independent re-implementation of the exported format, float32 compares
    exactly as sklearn's tree does. The Dart port is a line-for-line copy."""
    xf = np.asarray(x, dtype=np.float32)
    raw = doc["init_raw"]
    for tree in doc["trees"]:
        node = 0
        while tree["left"][node] != -1:
            f = tree["feature"][node]
            node = tree["left"][node] if xf[f] <= np.float32(tree["threshold"][node]) \
                else tree["right"][node]
        raw += doc["learning_rate"] * tree["value"][node]
    return 1.0 / (1.0 + np.exp(-raw))


def main():
    model = joblib.load(MODEL_PATH)
    assert type(model).__name__ == "GradientBoostingClassifier", type(model)
    assert model.n_features_in_ == len(FEATURES)

    doc = {
        "format": "sklearn-gbm-binary/v1",
        "sklearn_version": sklearn.__version__,
        "feature_names": FEATURES,
        "compare_as_float32": True,
        "learning_rate": float(model.learning_rate),
        "init_raw": float(model._raw_predict_init(np.zeros((1, len(FEATURES))))[0, 0]),
        "trees": [export_tree(est[0]) for est in model.estimators_],
        "tiers": TIERS,
        "feature_importances": {
            name: round(float(imp), 6)
            for name, imp in zip(FEATURES, model.feature_importances_)
        },
    }

    synthetic = generate_synthetic_data(400)[FEATURES].values.tolist()
    rows = [(name, v) for name, v in NAMED.items()]
    rows += [(f"synthetic #{i}", [float(a) for a in v]) for i, v in enumerate(synthetic[:60])]

    vectors, worst = [], 0.0
    for name, v in rows:
        expected = float(model.predict_proba(np.array([v], dtype=float))[0][1])
        mine = float(reference_proba(doc, v))
        worst = max(worst, abs(expected - mine))
        vectors.append({
            "name": name,
            "features": dict(zip(FEATURES, [float(a) for a in v])),
            "expected_score": expected,
            "expected_limit": compute_offline_limit(expected),
        })

    for thr, lim in TIERS:  # tier table must match the backend function exactly
        assert compute_offline_limit(thr) == lim, (thr, lim)
        assert compute_offline_limit(max(0.0, thr - 1e-6)) != lim or thr == 0.0

    assert worst < 1e-9, f"export does not reproduce sklearn: max diff {worst}"

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "risk_model.json"), "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    with open(os.path.join(OUT_DIR, "parity_vectors.json"), "w") as f:
        json.dump({"tolerance": 0.02, "vectors": vectors}, f, indent=1)

    nodes = sum(len(t["left"]) for t in doc["trees"])
    tiers_hit = sorted({v["expected_limit"] for v in vectors})
    print(f"exported {len(doc['trees'])} trees / {nodes} nodes -> {OUT_DIR}")
    print(f"{len(vectors)} parity vectors, reference max diff {worst:.2e}, tiers covered {tiers_hit}")


if __name__ == "__main__":
    main()
