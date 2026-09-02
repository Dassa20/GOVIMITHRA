"""
conftest.py — shared pytest fixtures for the backend test suite.

IMPORTANT — where this must run:
app.py loads the ML model at import time (MODEL = joblib.load(...)),
not inside a function. That means `import app` will fail immediately
unless ml/models/best_model.pkl, feature_names.pkl, and
encoding_maps.pkl already exist at the expected relative path.

This is not a flaw in the tests — it's a real property of app.py.
So: copy this backend_tests/ folder into your actual backend/ folder
(next to the real app.py) before running pytest, so the real model
files are found exactly where the app already expects them.

A separate, real gotcha this file works around directly: pytest does
NOT automatically add your current working directory to sys.path —
it only adds the directory containing the test/conftest files
themselves (backend_tests/, in this case). That left `import app`
failing with ModuleNotFoundError even when pytest was correctly run
from inside backend/, since backend/ itself was never actually on
sys.path. The sys.path.insert() call below fixes this directly,
regardless of which directory pytest is invoked from.

What these fixtures do:
- Every test gets a FRESH, TEMPORARY SQLite database — never your
  real price_data.db. This is done by monkeypatching app.DB_PATH
  before any test runs, so nothing here can corrupt real production
  data, and tests are fully repeatable (same starting state every run).
- The real ML model, feature names, and encoding maps are loaded
  normally, unmocked — so prediction tests exercise your actual
  deployed model, not a fake stand-in.
"""
import os
import sys
import sqlite3
import tempfile
import pytest

# Real fix for a real bug: pytest adds the directory containing THIS
# file (backend_tests/) to sys.path automatically, but NOT its parent
# (backend/, where app.py actually lives) — regardless of which
# directory pytest was launched from. Without this line, `import app`
# below fails with ModuleNotFoundError even when everything is placed
# correctly. This makes the parent directory importable explicitly.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture()
def app_module(monkeypatch):
    """
    Imports the real app.py with DB_PATH redirected to a fresh temp
    file BEFORE import, so init_db() (called at import time) creates
    its tables in the temp DB, not the real one.
    """
    tmp_dir = tempfile.mkdtemp()
    tmp_db = os.path.join(tmp_dir, "test_price_data.db")

    # app.py computes DB_PATH from its own file location — we patch
    # the environment/module AFTER import instead, then re-init.
    import importlib
    import sys

    # Remove any previously-imported copy so DB_PATH recompute is real
    if "app" in sys.modules:
        del sys.modules["app"]

    import app as app_module  # noqa: this is the real backend app.py

    monkeypatch.setattr(app_module, "DB_PATH", tmp_db)
    app_module.init_db()

    yield app_module


@pytest.fixture()
def client(app_module):
    app_module.app.testing = True
    return app_module.app.test_client()


@pytest.fixture()
def seeded_db(app_module):
    """
    Inserts a small, known set of price_history rows — enough for
    compute_features() to have the minimum 4 rows it requires — plus
    one known admin_users test account, so tests don't depend on
    real project data at all.
    """
    conn = app_module.get_db()
    cur = conn.cursor()

    # 6 weekly rows for Cinnamon / Galle / Alba — enough for lag/MA
    # features. Dates are DD.MM.YYYY to match compute_features()'s
    # strict parse format exactly.
    rows = [
        ("07.01.2025", "Galle", "Cinnamon", "Alba", 4500, 4600, 120.0, 27.5, 78.0),
        ("14.01.2025", "Galle", "Cinnamon", "Alba", 4550, 4650, 100.0, 27.8, 76.0),
        ("21.01.2025", "Galle", "Cinnamon", "Alba", 4600, 4700, 90.0,  28.0, 75.0),
        ("28.01.2025", "Galle", "Cinnamon", "Alba", 4650, 4750, 80.0,  28.2, 74.0),
        ("04.02.2025", "Galle", "Cinnamon", "Alba", 4700, 4800, 70.0,  28.5, 73.0),
        ("11.02.2025", "Galle", "Cinnamon", "Alba", 4750, 4850, 60.0,  28.7, 72.0),
    ]
    for r in rows:
        cur.execute("""
            INSERT INTO price_history
            (date, district, crop, grade, avg_price, high_price,
             rainfall_mm, temp_c, humidity_pct)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, r)

    cur.execute("""
        INSERT OR IGNORE INTO admin_users
        (username, password, role, full_name, district, crop)
        VALUES ('test_staff', 'TestPass123', 'dea_staff', 'Test Staff', 'Galle', 'Cinnamon')
    """)

    conn.commit()
    conn.close()
    return app_module
