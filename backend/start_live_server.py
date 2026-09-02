"""
start_live_server.py — runs the REAL app.py as an actual live HTTP
server (not test_client()), pointed at a fresh, seeded test database.
Used so Playwright can drive the REAL admin_web.html against the REAL
backend, for genuine integration testing rather than isolated mocks.

Place this file directly in your backend/ folder (next to the real
app.py) before running it — same requirement as backend_tests/.

UPDATED: seed dates changed from Jan-Feb 2025 to recent 2026 dates.
The Price Table tab's default filter shows only the last 3 months —
the original 2025 dates now fall outside that window and would show
as "no data" until the date range was manually widened. This wasn't
an issue for the original login/dashboard tests (which don't use
date-filtered history), but does matter for price-table tests.
"""
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import app as app_module

# Redirect to a dedicated live-test DB (separate from your real
# price_data.db) before init_db() runs again, and seed it with known
# data so the UI has something real to show.
LIVE_TEST_DB = os.path.join(SCRIPT_DIR, 'live_test.db')
app_module.DB_PATH = LIVE_TEST_DB
if os.path.exists(LIVE_TEST_DB):
    os.remove(LIVE_TEST_DB)
app_module.init_db()

conn = app_module.get_db()
cur = conn.cursor()

# Recent dates (within the last 3 months of a run in August 2026) so
# they fall inside the Price Table tab's default date-filter window.
# If you run this well after August 2026, update these to be within
# 3 months of your actual run date.
rows = [
    ("05.07.2026", "Galle", "Cinnamon", "Alba", 4500, 4600, 120.0, 27.5, 78.0),
    ("12.07.2026", "Galle", "Cinnamon", "Alba", 4550, 4650, 100.0, 27.8, 76.0),
    ("19.07.2026", "Galle", "Cinnamon", "Alba", 4600, 4700, 90.0, 28.0, 75.0),
    ("26.07.2026", "Galle", "Cinnamon", "Alba", 4650, 4750, 80.0, 28.2, 74.0),
    ("02.08.2026", "Galle", "Cinnamon", "Alba", 4700, 4800, 70.0, 28.5, 73.0),
    ("09.08.2026", "Galle", "Cinnamon", "Alba", 4750, 4850, 60.0, 28.7, 72.0),
]
for r in rows:
    cur.execute("""
        INSERT INTO price_history
        (date, district, crop, grade, avg_price, high_price,
         rainfall_mm, temp_c, humidity_pct)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, r)
conn.commit()
conn.close()

print(f"Live test DB created at: {LIVE_TEST_DB}")
print("Live test server starting on http://127.0.0.1:5050", flush=True)
app_module.app.run(host='127.0.0.1', port=5050, debug=False, threaded=True)
