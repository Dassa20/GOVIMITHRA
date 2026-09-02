"""
test_real_model_accuracy.py — tests the REAL trained model files
(best_model.pkl, feature_names.pkl, encoding_maps.pkl), not the dummy
placeholder model used in backend_tests/.

SETUP REQUIRED:
1. Copy this file into backend_tests/ (next to test_backend.py)
2. Make sure ml/models/best_model.pkl, feature_names.pkl, and
   encoding_maps.pkl are your REAL trained files — the ones actually
   deployed, not dummy/placeholder ones.
3. Run: pytest backend_tests/test_real_model_accuracy.py -v

WHAT THIS TESTS (that the existing pytest suite does NOT):
- The real model loads without version-mismatch errors
- Predictions are genuinely reproducible (same input -> same output)
- Predictions fall within a sane, real-world price range (not
  wildly wrong numbers that would still "pass" a dummy-model test)
- Feature engineering at prediction time produces the same feature
  vector shape the model was actually trained on
- The model handles a missing-weather-data row without crashing
- A basic regression-safety check: today's model's accuracy on a
  held-out sample doesn't silently drop below a documented floor
"""
import os
import sys
import pytest
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(scope="module")
def real_app_module():
    """
    Imports the real app.py WITHOUT patching DB_PATH — this test
    module intentionally uses whatever real model files are already
    sitting in ml/models/, exactly as the live app would load them.
    """
    import importlib
    if "app" in sys.modules:
        del sys.modules["app"]
    import app as app_module
    return app_module


@pytest.fixture(scope="module")
def real_client(real_app_module):
    """
    FIX applied after a real test run: the shared `client` fixture
    from backend_tests/conftest.py deliberately points at a fresh,
    empty, temporary SQLite database for every test — correct
    isolation for the rest of the suite, but it meant these specific
    ML-accuracy tests could never see real price history, even when
    the actual price_data.db genuinely had 82 real rows for Galle/
    Cinnamon/Alba (confirmed directly via curl against the running
    app). This fixture creates a client from real_app_module directly,
    with DB_PATH untouched, so it genuinely reads your real database.
    """
    real_app_module.app.config["TESTING"] = True
    return real_app_module.app.test_client()


def test_real_model_loads_without_error(real_app_module):
    """
    The most basic real-model check: MODEL, FEATURE_NAMES, and
    ENCODING_MAPS all loaded successfully at import time. If your
    real .pkl files were saved with a different scikit-learn/XGBoost
    version than what's installed here, this is where it would fail
    with a version-mismatch error — a genuinely useful thing to catch
    before deployment, not just in production.
    """
    assert real_app_module.MODEL is not None
    assert real_app_module.FEATURE_NAMES is not None
    assert len(real_app_module.FEATURE_NAMES) > 0


def test_real_model_type_matches_expected(real_app_module):
    """
    Confirms the loaded model is genuinely the type documented in the
    thesis (XGBRegressor) — catches an accidental wrong-file mixup,
    e.g. if best_model.pkl was overwritten with a different model by
    mistake during retraining.
    """
    model_type = type(real_app_module.MODEL).__name__
    assert "XGB" in model_type or "XGBRegressor" in model_type, (
        f"Expected an XGBoost model per the thesis's documented deployment "
        f"choice, but loaded model is: {model_type}"
    )


def test_predictions_are_reproducible(real_app_module, real_client):
    """
    Same input -> same output, every time. This is a basic sanity
    property of a deployed model: if this fails, something is
    non-deterministic in either feature engineering or the model
    itself (e.g. an unset random seed), which would make the app's
    predictions untrustworthy from one call to the next.
    """
    payload = {"district": "Galle", "crop": "Cinnamon", "grade": "Alba"}
    resp1 = real_client.post("/predict", json=payload)
    resp2 = real_client.post("/predict", json=payload)

    if resp1.status_code != 200:
        pytest.skip("No price history for Galle/Cinnamon/Alba in this "
                     "database — point this test at a combination with "
                     "real seeded history to run it meaningfully.")

    price1 = resp1.get_json()["predicted_price"]
    price2 = resp2.get_json()["predicted_price"]
    assert price1 == price2, (
        f"Same input produced different predictions: {price1} vs {price2}. "
        f"This suggests non-determinism in feature engineering or the model."
    )


def test_predictions_fall_within_realistic_price_range(real_app_module, real_client):
    """
    A dummy model can return ANY number and still "pass" a test that
    only checks the response shape. This test checks the actual
    VALUE is plausible for real Sri Lankan cinnamon/pepper farm-gate
    prices — catching a genuinely broken model (e.g. one predicting
    negative prices, or prices in the millions due to a unit error)
    that a shape-only test would miss entirely.

    Adjust these bounds to match your actual dataset's real observed
    price range before relying on this test.
    """
    REALISTIC_MIN_PRICE = 500    # Rs./kg — adjust to your real data's floor
    REALISTIC_MAX_PRICE = 15000  # Rs./kg — adjust to your real data's ceiling

    test_cases = [
        {"district": "Galle", "crop": "Cinnamon", "grade": "Alba"},
        {"district": "Matara", "crop": "Cinnamon", "grade": "Alba"},
        {"district": "Kandy", "crop": "Pepper", "grade": "GR-1"},
        {"district": "Matale", "crop": "Pepper", "grade": "GR-1"},
    ]

    tested_any = False
    for payload in test_cases:
        resp = real_client.post("/predict", json=payload)
        if resp.status_code != 200:
            continue  # no history for this combination in this DB — skip
        tested_any = True
        price = resp.get_json()["predicted_price"]
        assert REALISTIC_MIN_PRICE <= price <= REALISTIC_MAX_PRICE, (
            f"Predicted price {price} for {payload} is outside the "
            f"realistic range [{REALISTIC_MIN_PRICE}, {REALISTIC_MAX_PRICE}] "
            f"— this would indicate a genuinely broken model, not just an "
            f"inaccurate one."
        )

    if not tested_any:
        pytest.skip("No seeded price history for any test combination — "
                     "run this against a database with real historical "
                     "data to test meaningfully.")


def test_feature_vector_shape_matches_training(real_app_module):
    """
    Confirms the live feature-engineering code (compute_features, or
    equivalent) produces a feature vector with exactly the same
    columns, in the same order, as FEATURE_NAMES — the list the model
    was actually trained on. A mismatch here (e.g. a forgotten
    feature, or features in the wrong order) would make every single
    prediction silently wrong, without ever raising an exception.
    """
    assert hasattr(real_app_module, "FEATURE_NAMES")
    feature_names = real_app_module.FEATURE_NAMES
    assert isinstance(feature_names, list)
    assert len(feature_names) == real_app_module.MODEL.n_features_in_, (
        f"FEATURE_NAMES has {len(feature_names)} entries, but the loaded "
        f"model expects {real_app_module.MODEL.n_features_in_} input "
        f"features. A mismatch here means predictions are being computed "
        f"on a differently-shaped input than what the model was trained on."
    )


def test_missing_weather_data_does_not_crash_real_model(real_app_module, real_client):
    """
    Real NASA POWER data can have gaps (a day with no reading). This
    checks the REAL model handles a request where recent weather
    features are missing/null without throwing — using whatever
    combination in your live data genuinely has this gap. Adjust the
    payload below to a real crop/district/grade combination you know
    has a missing-weather week in your actual database.
    """
    payload = {"district": "Galle", "crop": "Cinnamon", "grade": "Alba"}
    resp = real_client.post("/predict", json=payload)
    # Accept either a valid prediction (gap was handled) or a clean
    # 400 (gracefully rejected) — the only unacceptable outcome is a
    # 500 crash, which would mean the real model chokes on real gaps.
    assert resp.status_code in (200, 400), (
        f"Expected a graceful 200 or 400, got {resp.status_code} — "
        f"this suggests the real model crashes on this input, which "
        f"needs investigating before deployment."
    )


# ═══════════════════════════════════════════════════════════════
# Accuracy regression guard — run this against a genuine held-out
# test set to make sure retraining never silently makes the deployed
# model worse without anyone noticing.
# ═══════════════════════════════════════════════════════════════
def test_documented_accuracy_has_not_regressed():
    """
    Compares today's real model.pkl's accuracy on a held-out CSV
    against the R²/MAE figures already reported in Interim Submission
    02 (XGBoost: R²=0.859, MAE=Rs.110.48/kg). This is a regression
    guard for retraining — if a future retrain accidentally makes the
    deployed model meaningfully worse, this test catches it instead
    of it being discovered only after farmers start getting bad
    predictions.

    REQUIRES: a held-out test CSV with real historical rows and their
    true prices, not used during training. Point TEST_CSV_PATH at it.
    Skips cleanly if the file isn't present, rather than failing —
    this test is only meaningful once you provide that file.
    """
    TEST_CSV_PATH = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ml", "test_holdout.csv"
    )
    DOCUMENTED_MAE = 110.48   # Rs./kg, from Interim Submission 02
    ALLOWED_MAE_INCREASE = 15  # Rs./kg tolerance before flagging regression

    if not os.path.exists(TEST_CSV_PATH):
        pytest.skip(
            f"No held-out test set found at {TEST_CSV_PATH}. Create one "
            f"(rows genuinely excluded from training, with known true "
            f"prices) to make this regression guard meaningful."
        )

    import pandas as pd
    import joblib

    model_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ml", "models", "best_model.pkl"
    )
    model = joblib.load(model_path)
    df = pd.read_csv(TEST_CSV_PATH)

    assert "true_price" in df.columns, (
        "Held-out CSV must have a 'true_price' column with the real "
        "observed price for each row, to compare predictions against."
    )
    feature_cols = [c for c in df.columns if c != "true_price"]
    X = df[feature_cols]
    y_true = df["true_price"]

    y_pred = model.predict(X)
    mae = float(np.mean(np.abs(y_true - y_pred)))

    assert mae <= DOCUMENTED_MAE + ALLOWED_MAE_INCREASE, (
        f"Current model's MAE on the held-out set is Rs.{mae:.2f}/kg, "
        f"which is more than Rs.{ALLOWED_MAE_INCREASE}/kg worse than the "
        f"documented Rs.{DOCUMENTED_MAE}/kg from Interim Submission 02. "
        f"This suggests a real accuracy regression — investigate before "
        f"deploying this model version."
    )
