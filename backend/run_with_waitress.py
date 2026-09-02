"""
run_with_waitress.py — runs your REAL app.py through waitress, a
production-grade WSGI server that works well on Windows, INSTEAD of
Flask's built-in development server.

WHY: Locust testing showed ~55% failures even at just 10 concurrent
users, with failing requests consistently taking ~2000ms — and this
persisted even after adding an explicit 30-second client-side
timeout, which rules out the Locust test file itself as the cause.
Flask's dev server (what `python app.py` runs) is explicitly not
built for concurrent load — its own startup banner says so directly.
This script tests whether that's the real, whole explanation.

SETUP:
    pip install waitress --break-system-packages

RUN (instead of `python app.py`):
    python run_with_waitress.py

Then re-run the exact same Locust test against it — same host/port,
same locustfile.py, same user count. If failures drop dramatically
or disappear, that CONFIRMS the dev server's concurrency handling was
the real cause, not a bug in your actual application code — and
waitress (or an equivalent production server) is a legitimate,
standard fix to document, not a workaround.
"""
import importlib
import sys

# Import app.py as a module WITHOUT triggering its own app.run() call
# (that only fires under `if __name__ == '__main__'`, which importing
# as a module doesn't trigger) — this gives us the real Flask `app`
# object, fully configured exactly as it is in production use, just
# without Werkzeug's dev server driving it.
if "app" in sys.modules:
    del sys.modules["app"]
import app as app_module

from waitress import serve

print("Starting the REAL app through waitress (production WSGI server)")
print("Same routes, same model, same database — just a different server.")
print("Listening on http://127.0.0.1:5000")
print("Press CTRL+C to quit\n")

serve(app_module.app, host="127.0.0.1", port=5000, threads=8)
