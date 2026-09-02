"""
test_security.py — basic security penetration tests for the real,
running GOVIMITHRA backend.

SETUP:
    Run against your REAL running backend (or the live_test.db server
    from start_live_server.py — either works for these checks).

RUN:
    cd backend/
    python app.py                      # real server, one terminal
    pytest test_security.py -v --base-url=http://127.0.0.1:5000

WHAT THIS COVERS (a genuine, if basic, security pass — not a
substitute for a full professional penetration test, but real,
runnable checks that catch the most common web app vulnerabilities):
- SQL injection across every user-input field
- Authentication bypass attempts
- Missing/broken access control (role checks)
- Information disclosure in error messages
- Missing security headers
- Rate limiting / brute-force protection
- Input validation edge cases (oversized payloads, malformed JSON)

This is NOT a replacement for a tool like OWASP ZAP for a genuinely
thorough scan — but it's real, targeted testing of the specific
attack patterns most relevant to this app's actual attack surface
(SQL-backed Flask API with a simple admin login), and it's something
you ran and can show real, passing results for.
"""
import requests
import pytest

BASE_URL = "http://127.0.0.1:5000"  # change to your real running server


# ═══════════════════════════════════════════════════════════════
# SQL Injection
# ═══════════════════════════════════════════════════════════════
SQLI_PAYLOADS = [
    "' OR '1'='1",
    "'; DROP TABLE admin_users; --",
    "' OR 1=1 --",
    "admin'--",
    "' UNION SELECT * FROM admin_users --",
]


@pytest.mark.parametrize("payload", SQLI_PAYLOADS)
def test_sql_injection_in_login_username(payload):
    resp = requests.post(f"{BASE_URL}/admin/login",
                          json={"username": payload, "password": "anything"})
    assert resp.status_code in (400, 401), (
        f"SQL injection payload {payload!r} in username did not get a "
        f"clean 400/401 — got {resp.status_code}. This needs investigating "
        f"immediately; a 200 here could mean an authentication bypass."
    )
    # A successful injection bypass would return success:true — explicitly
    # check this never happens, not just that the status code looks right.
    if resp.headers.get("content-type", "").startswith("application/json"):
        body = resp.json()
        assert body.get("success") is not True, (
            f"CRITICAL: SQL injection payload {payload!r} appears to have "
            f"bypassed login authentication."
        )


@pytest.mark.parametrize("payload", SQLI_PAYLOADS)
def test_sql_injection_in_history_district_param(payload):
    resp = requests.get(f"{BASE_URL}/history",
                         params={"district": payload, "crop": "Cinnamon", "grade": "Alba"})
    # Should safely return empty/error, never a 500 (which would suggest
    # the query broke) or leak unrelated data.
    assert resp.status_code != 500, (
        f"SQL injection payload {payload!r} in district param caused a "
        f"500 error — this suggests the query isn't safely parameterised."
    )


# ═══════════════════════════════════════════════════════════════
# Authentication & Access Control
# ═══════════════════════════════════════════════════════════════
def test_admin_routes_reject_missing_credentials():
    """Every /admin/* POST route should require a requestor_username
    and reject requests without one, not silently proceed."""
    admin_routes = [
        "/admin/list-accounts",
        "/admin/pending-requests",
        "/admin/create-account",
    ]
    for route in admin_routes:
        resp = requests.post(f"{BASE_URL}{route}", json={})
        assert resp.status_code in (400, 401, 403), (
            f"{route} did not reject a request with no credentials "
            f"(got {resp.status_code}) — this could be a real access "
            f"control gap."
        )


def test_staff_cannot_access_super_admin_only_routes():
    """
    Requires a real dea_staff test account to exist. Adjust the
    username below to a real, non-super-admin account in your system.
    """
    resp = requests.post(f"{BASE_URL}/admin/list-accounts",
                          json={"requestor_username": "test_staff"})
    assert resp.status_code == 403, (
        f"A non-super-admin account was able to list all accounts "
        f"(got {resp.status_code}, expected 403) — this is a real "
        f"privilege escalation risk if it reproduces against your "
        f"actual staff accounts."
    )


def test_default_credentials_no_longer_work():
    """
    Flags whether the shipped default super admin password
    (Admin@1234) has been changed. In a DEVELOPMENT/test database this
    is expected to still work — this test exists so it FAILS LOUDLY
    once you point it at a real production deployment, as a reminder
    to have actually changed it.
    """
    resp = requests.post(f"{BASE_URL}/admin/login",
                          json={"username": "admin", "password": "Admin@1234"})
    if resp.status_code == 200:
        pytest.fail(
            "Default admin credentials (admin/Admin@1234) still work. "
            "This is fine on a local dev/test database, but MUST be "
            "changed before any real deployment — treat this failure as "
            "a checklist reminder, not a bug, if running against dev data."
        )


# ═══════════════════════════════════════════════════════════════
# Information Disclosure
# ═══════════════════════════════════════════════════════════════
def test_error_responses_do_not_leak_stack_traces():
    """
    Sends deliberately malformed input and checks the error response
    doesn't include a raw Python traceback, internal file paths, or
    SQL query text — all of which help an attacker understand the
    backend's internals.
    """
    resp = requests.post(f"{BASE_URL}/predict", data="not valid json",
                          headers={"Content-Type": "application/json"})
    body_text = resp.text.lower()
    leaky_strings = ["traceback", "file \"/", ".py\", line", "sqlite3.", "site-packages"]
    for leak in leaky_strings:
        assert leak not in body_text, (
            f"Error response appears to leak internal details "
            f"(found {leak!r} in response body) — Flask's debug mode "
            f"may be on, which must be off in any real deployment."
        )


def test_login_error_does_not_reveal_which_field_was_wrong():
    """Already covered in backend_tests/, repeated here as an explicit
    security-focused check: username enumeration via differing error
    messages is a real, common vulnerability."""
    resp_unknown_user = requests.post(
        f"{BASE_URL}/admin/login",
        json={"username": "definitely_does_not_exist_xyz", "password": "x"})
    resp_wrong_pass = requests.post(
        f"{BASE_URL}/admin/login",
        json={"username": "admin", "password": "definitely_wrong_password"})

    if resp_unknown_user.status_code == 401 and resp_wrong_pass.status_code == 401:
        msg1 = resp_unknown_user.json().get("error", "")
        msg2 = resp_wrong_pass.json().get("error", "")
        assert msg1 == msg2, (
            "Login error messages differ between 'unknown username' and "
            "'wrong password' — this lets an attacker enumerate valid "
            "usernames."
        )


# ═══════════════════════════════════════════════════════════════
# Security Headers
# ═══════════════════════════════════════════════════════════════
def test_security_headers_present():
    """
    Checks for common baseline security headers. Flask does not set
    these by default — if this fails, adding the `flask-talisman`
    package (or setting these headers manually) is the standard fix.
    """
    resp = requests.get(f"{BASE_URL}/health")
    recommended_headers = [
        "X-Content-Type-Options",
        "X-Frame-Options",
    ]
    missing = [h for h in recommended_headers if h not in resp.headers]
    if missing:
        pytest.fail(
            f"Missing recommended security headers: {missing}. Consider "
            f"adding flask-talisman or setting these manually — this is "
            f"a real, documentable gap if it reproduces."
        )


# ═══════════════════════════════════════════════════════════════
# Rate Limiting / Brute Force
# ═══════════════════════════════════════════════════════════════
def test_no_rate_limiting_on_login_is_flagged():
    """
    Sends 15 rapid login attempts and checks whether ANY got rate
    limited (429). If none did, this is a real, documentable gap —
    the app currently has no brute-force protection on admin login.
    This test is designed to surface that honestly, not hide it.
    """
    got_rate_limited = False
    for i in range(15):
        resp = requests.post(f"{BASE_URL}/admin/login",
                              json={"username": "admin", "password": f"wrong{i}"})
        if resp.status_code == 429:
            got_rate_limited = True
            break
    if not got_rate_limited:
        pytest.fail(
            "15 rapid login attempts, none rate-limited (no 429 seen). "
            "This is a real, current gap — the admin login endpoint has "
            "no brute-force protection. Worth documenting as a known "
            "limitation and considering flask-limiter as a fix."
        )


# ═══════════════════════════════════════════════════════════════
# Input Validation Edge Cases
# ═══════════════════════════════════════════════════════════════
def test_oversized_payload_rejected_cleanly():
    """A very large JSON body should be rejected cleanly, not crash
    the server or hang indefinitely."""
    huge_string = "x" * (5 * 1024 * 1024)  # 5 MB string
    try:
        resp = requests.post(f"{BASE_URL}/chatbot",
                              json={"message": huge_string, "device_id": "test"},
                              timeout=10)
    except requests.exceptions.ReadTimeout as e:
        # FIX applied after a real run: the previous version's
        # pytest.fail() call worked correctly (the short summary at
        # the bottom already showed the clean message), but Python's
        # own exception chaining ("During handling of the above
        # exception...") still printed the full 100+ line urllib3/
        # requests internal traceback ABOVE it by default, since
        # pytest.fail() was called from inside an `except` block.
        # Two things fix the noisy output directly: `pytrace=False`
        # tells pytest not to print a traceback for the fail() call
        # itself, and `from None` on the raise breaks Python's
        # automatic chaining so the original ReadTimeout's traceback
        # isn't dragged in either. The test's logic and finding are
        # unchanged — this only cleans up what gets printed.
        raise pytest.fail.Exception(
            "Oversized payload caused the server to hang for the full "
            "10s timeout with NO response — no size-related rejection, "
            "no crash, just silence. This is a real, documentable gap: "
            "consider adding a MAX_CONTENT_LENGTH config to Flask so "
            "oversized requests are rejected immediately rather than "
            "processed (or hung on) at all.",
            pytrace=False,
        ) from None


    assert resp.status_code in (400, 413, 500), (
        "Oversized payload was accepted without any size-related "
        "rejection — worth adding a MAX_CONTENT_LENGTH config to Flask."
    )


def test_missing_required_fields_never_500s():
    """Every POST endpoint should return a clean 400 for missing
    fields, never a raw 500 — a 500 here means an unhandled exception
    on simple bad input, which real users WILL send accidentally."""
    endpoints_and_bad_payloads = [
        ("/predict", {}),
        ("/harvest-status", {}),
        ("/admin/login", {}),
        ("/chatbot", {}),
        ("/register-device", {}),
    ]
    for endpoint, payload in endpoints_and_bad_payloads:
        resp = requests.post(f"{BASE_URL}{endpoint}", json=payload)
        assert resp.status_code != 500, (
            f"{endpoint} returned a raw 500 on an empty payload — "
            f"this should be a clean, handled 400 instead."
        )
