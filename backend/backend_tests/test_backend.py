"""
test_backend.py — automated tests for the real Flask backend.

Run from inside your backend/ folder, with this file's parent folder
(backend_tests/) copied in next to app.py:

    pip install pytest --break-system-packages
    pytest backend_tests/ -v

Each test below is tied to a specific behaviour that was discussed
and fixed during development — not generic boilerplate. Where a test
name references a bug (e.g. "grade_scoped_per_district"), that's a
direct regression test for that fix.
"""
import json


# ═══════════════════════════════════════════════════════════════
# A.0 — Health / sanity
# ═══════════════════════════════════════════════════════════════
def test_health_endpoint_is_up(client):
    resp = client.get("/health")
    assert resp.status_code == 200


# ═══════════════════════════════════════════════════════════════
# A.1 — /metadata
# ═══════════════════════════════════════════════════════════════
def test_metadata_returns_empty_structure_when_db_is_empty(client):
    """
    With no rows at all, metadata should return empty lists/dicts,
    not crash.

    NOTE — real finding from running this test against the actual
    app.py: the empty-DB response does NOT include the
    'grades_by_crop_district' key at all (only the older
    'grades_by_crop' key is present), while the non-empty response
    always includes both. This is a minor response-shape asymmetry
    worth being aware of if the frontend ever reads
    grades_by_crop_district before checking it exists — worth a
    one-line fix in app.py's empty-df branch to include it as {}
    for consistency, though it isn't causing a crash today.
    """
    resp = client.get("/metadata")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["crops"] == []
    assert data.get("grades_by_crop_district", {}) == {}


def test_metadata_includes_seeded_crop_after_minimum_rows(seeded_db, client):
    resp = client.get("/metadata")
    data = resp.get_json()
    assert "Cinnamon" in data["crops"]
    assert "Galle" in data["districts_by_crop"].get("Cinnamon", [])


def test_metadata_grades_are_scoped_per_district_not_just_per_crop(seeded_db, client):
    """
    Direct regression test for the real data-integrity bug found
    earlier: a grade must only appear as available for a district it
    actually has rows for, via grades_by_crop_district — NOT via the
    old grades_by_crop union, which could offer a grade with zero
    rows for a given district and always return a 400 at predict time.
    """
    resp = client.get("/metadata")
    data = resp.get_json()
    galle_grades = data["grades_by_crop_district"].get("Cinnamon", {}).get("Galle", [])
    assert "Alba" in galle_grades
    # A district with NO seeded rows must not falsely show any grade
    matara_grades = data["grades_by_crop_district"].get("Cinnamon", {}).get("Matara", [])
    assert matara_grades == [] or "Matara" not in data["grades_by_crop_district"].get("Cinnamon", {})


# ═══════════════════════════════════════════════════════════════
# A.2 — /predict
# ═══════════════════════════════════════════════════════════════
def test_predict_missing_fields_returns_400(client):
    resp = client.post("/predict", json={"crop": "Cinnamon"})  # district, grade missing
    assert resp.status_code == 400
    assert "error" in resp.get_json()


def test_predict_insufficient_history_returns_400_not_500(client):
    """A crop/district/grade combination with zero rows must fail
    cleanly with a 400, not crash the server with a 500."""
    resp = client.post("/predict", json={
        "crop": "Pepper", "district": "Kandy", "grade": "GR-1",
    })
    assert resp.status_code == 400
    assert "error" in resp.get_json()


def test_predict_returns_full_expected_shape_with_enough_history(seeded_db, client):
    resp = client.post("/predict", json={
        "crop": "Cinnamon", "district": "Galle", "grade": "Alba",
    })
    assert resp.status_code == 200
    data = resp.get_json()
    for key in ["predicted_price", "last_known_price", "predicted_for_date",
                "price_change", "price_change_pct", "season", "is_harvest_season"]:
        assert key in data, f"missing expected field: {key}"
    assert isinstance(data["predicted_price"], (int, float))


def test_predict_response_has_no_nan_or_infinity(seeded_db, client):
    """Verifies the custom _SafeJSONProvider actually does its job —
    NaN/Infinity must come through as null, never as literal NaN
    (which is invalid JSON and breaks strict JSON parsers)."""
    resp = client.post("/predict", json={
        "crop": "Cinnamon", "district": "Galle", "grade": "Alba",
    })
    raw = resp.get_data(as_text=True)
    assert "NaN" not in raw
    assert "Infinity" not in raw


# ═══════════════════════════════════════════════════════════════
# A.3 — /harvest-status (pure logic, no DB/model needed)
# ═══════════════════════════════════════════════════════════════
def test_harvest_status_unknown_crop_returns_400(client):
    resp = client.post("/harvest-status", json={"crop": "Banana", "district": "Galle"})
    assert resp.status_code == 400


def test_harvest_status_known_crop_returns_valid_shape(client):
    resp = client.post("/harvest-status", json={"crop": "Cinnamon", "district": "Galle"})
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["status"] in ("Ready to Harvest", "Not Harvest Season")
    assert isinstance(data["is_harvest_season"], bool)


# ═══════════════════════════════════════════════════════════════
# A.4 — /admin/login
# ═══════════════════════════════════════════════════════════════
def test_admin_login_succeeds_with_correct_credentials(seeded_db, client):
    resp = client.post("/admin/login", json={
        "username": "test_staff", "password": "TestPass123",
    })
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["success"] is True
    assert data["role"] == "dea_staff"


def test_admin_login_fails_with_wrong_password(seeded_db, client):
    resp = client.post("/admin/login", json={
        "username": "test_staff", "password": "WrongPassword",
    })
    assert resp.status_code == 401
    assert resp.get_json()["success"] is False


def test_admin_login_does_not_leak_which_field_was_wrong(seeded_db, client):
    """Security check: the error message must not reveal whether the
    username or the password was the incorrect part — that
    information helps an attacker enumerate valid usernames."""
    resp_bad_user = client.post("/admin/login", json={
        "username": "nonexistent_user", "password": "TestPass123",
    })
    resp_bad_pass = client.post("/admin/login", json={
        "username": "test_staff", "password": "WrongPassword",
    })
    assert resp_bad_user.get_json()["message"] == resp_bad_pass.get_json()["message"]


def test_admin_login_sql_injection_attempt_is_safely_rejected(seeded_db, client):
    """
    Real security test — app.py uses parameterised queries
    (WHERE username=? AND password=?), so this should fail cleanly
    as invalid credentials, not succeed or throw a server error.
    """
    resp = client.post("/admin/login", json={
        "username": "test_staff' OR '1'='1",
        "password": "anything",
    })
    assert resp.status_code == 401


def test_default_super_admin_password_is_still_the_documented_default(seeded_db, client):
    """
    This is a DELIBERATE warning test, not a bug report: init_db()
    creates a default super admin (admin / Admin@1234) if none
    exists. This test passing means that default is still active —
    it should be changed before any real deployment. If you've
    already changed it in your real DB, this specific test won't
    apply there (it only runs against the fresh seeded test DB).
    """
    resp = client.post("/admin/login", json={
        "username": "admin", "password": "Admin@1234",
    })
    assert resp.status_code == 200, (
        "Note: this failing is actually GOOD news if you already "
        "changed the real default admin password."
    )


# ═══════════════════════════════════════════════════════════════
# A.5 — General error handling
# ═══════════════════════════════════════════════════════════════
def test_predict_with_malformed_json_does_not_500(client):
    resp = client.post("/predict", data="not valid json",
                        content_type="application/json")
    assert resp.status_code in (400, 415), \
        f"malformed JSON should be rejected cleanly, got {resp.status_code}"


def test_chatbot_without_message_returns_400(app_module, client, monkeypatch):
    """
    GEMINI_API_KEY must be set for the endpoint to even reach its
    message-validation check (it returns 503 first if the key is
    missing, which is itself correct, tested separately below). A
    dummy key is set here purely to reach and test the validation
    logic that comes after that check.
    """
    monkeypatch.setattr(app_module, "GEMINI_API_KEY", "dummy-key-for-testing")
    resp = client.post("/chatbot", json={"device_id": "test-device-1"})
    assert resp.status_code == 400


def test_chatbot_returns_503_when_not_configured(app_module, client, monkeypatch):
    monkeypatch.setattr(app_module, "GEMINI_API_KEY", "")
    resp = client.post("/chatbot", json={"message": "hello", "device_id": "test-device-1"})
    assert resp.status_code == 503


# ═══════════════════════════════════════════════════════════════
# B — /history
# ═══════════════════════════════════════════════════════════════
def test_history_missing_params_returns_400(client):
    resp = client.get("/history?crop=Cinnamon")  # district, grade missing
    assert resp.status_code == 400


def test_history_returns_seeded_rows_in_date_order(seeded_db, client):
    resp = client.get("/history?district=Galle&crop=Cinnamon&grade=Alba")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["count"] == 6
    dates = [row["date"] for row in data["data"]]
    assert dates == sorted(dates, key=lambda d: (d[6:], d[3:5], d[0:2])), \
        "rows should be sorted by actual date, not string order"


def test_history_respects_limit_param(seeded_db, client):
    resp = client.get("/history?district=Galle&crop=Cinnamon&grade=Alba&limit=2")
    data = resp.get_json()
    assert data["count"] == 2


def test_history_empty_for_unknown_combination_not_an_error(seeded_db, client):
    resp = client.get("/history?district=Kandy&crop=Pepper&grade=GR-1")
    assert resp.status_code == 200
    assert resp.get_json()["count"] == 0


# ═══════════════════════════════════════════════════════════════
# C — /register-device
# ═══════════════════════════════════════════════════════════════
def test_register_device_missing_token_returns_400(client):
    resp = client.post("/register-device", json={"district": "Galle"})
    assert resp.status_code == 400


def test_register_device_succeeds_anonymously_without_email(app_module, client):
    """Confirms the documented behaviour: email is optional, anonymous
    device registration for notifications is supported."""
    resp = client.post("/register-device", json={
        "fcm_token": "test-fcm-token-abc123",
        "district": "Galle", "crop": "Cinnamon", "grade": "Alba",
    })
    assert resp.status_code == 200


# ═══════════════════════════════════════════════════════════════
# D — Admin account management
# ═══════════════════════════════════════════════════════════════
def test_create_account_rejects_non_super_admin(seeded_db, client):
    resp = client.post("/admin/create-account", json={
        "requestor_username": "test_staff",  # dea_staff, not super_admin
        "username": "new_user", "password": "pw123",
    })
    assert resp.status_code == 403


def test_create_account_succeeds_for_super_admin(seeded_db, client):
    resp = client.post("/admin/create-account", json={
        "requestor_username": "admin",
        "username": "new_staff_member", "password": "SecurePass1",
        "role": "dea_staff", "district": "Matara", "crop": "Cinnamon",
    })
    assert resp.status_code == 200
    assert resp.get_json()["success"] is True


def test_create_account_duplicate_username_fails_cleanly(seeded_db, client):
    resp = client.post("/admin/create-account", json={
        "requestor_username": "admin",
        "username": "test_staff",  # already exists from seeded_db
        "password": "AnotherPass1",
    })
    assert resp.status_code == 409, "duplicate username should fail, not silently overwrite"


def test_list_accounts_rejects_non_super_admin(seeded_db, client):
    resp = client.post("/admin/list-accounts", json={"requestor_username": "test_staff"})
    assert resp.status_code == 403


def test_list_accounts_returns_seeded_account_for_super_admin(seeded_db, client):
    resp = client.post("/admin/list-accounts", json={"requestor_username": "admin"})
    assert resp.status_code == 200
    usernames = [a["username"] for a in resp.get_json()["accounts"]]
    assert "test_staff" in usernames


def test_delete_account_cannot_delete_own_account(seeded_db, client):
    resp = client.post("/admin/delete-account", json={
        "requestor_username": "admin", "target_username": "admin",
    })
    assert resp.status_code == 400


def test_delete_account_rejects_non_super_admin(seeded_db, client):
    resp = client.post("/admin/delete-account", json={
        "requestor_username": "test_staff", "target_username": "admin",
    })
    assert resp.status_code == 403


def test_delete_account_succeeds_for_super_admin(seeded_db, client):
    resp = client.post("/admin/delete-account", json={
        "requestor_username": "admin", "target_username": "test_staff",
    })
    assert resp.status_code == 200
    # Confirm it's actually gone, not just a success message
    login_resp = client.post("/admin/login", json={
        "username": "test_staff", "password": "TestPass123",
    })
    assert login_resp.status_code == 401


# ═══════════════════════════════════════════════════════════════
# E — Price request submission + approval workflow (end-to-end
# within the backend, not just single endpoints in isolation)
# ═══════════════════════════════════════════════════════════════
def test_staff_submit_request_unauthorized_for_unknown_user(client):
    resp = client.post("/admin/submit-price-request", json={
        "submitted_by": "nonexistent_user",
        "district": "Galle", "crop": "Cinnamon", "grade": "Alba",
        "date": "18.02.2025", "avg_price": 4800,
    })
    assert resp.status_code == 401


def test_full_request_and_approval_workflow_updates_price_history(seeded_db, client):
    """
    This is the closest thing to an integration test within the
    backend test suite: submit as staff, list as pending, approve as
    super admin, then confirm the price genuinely landed in
    price_history — not just that each endpoint individually returns
    200 in isolation.
    """
    submit_resp = client.post("/admin/submit-price-request", json={
        "submitted_by": "test_staff",
        "district": "Galle", "crop": "Cinnamon", "grade": "Alba",
        "date": "18.02.2025", "avg_price": 4900, "high_price": 5000,
        "rainfall_mm": 65.0, "temp_c": 28.9, "humidity_pct": 71.0,
    })
    assert submit_resp.status_code == 200
    request_id = submit_resp.get_json()["request_id"]

    pending_resp = client.post("/admin/pending-requests",
                                json={"requestor_username": "admin"})
    pending_ids = [r["id"] for r in pending_resp.get_json()["requests"]]
    assert request_id in pending_ids

    approve_resp = client.post("/admin/review-request", json={
        "requestor_username": "admin", "request_id": request_id,
        "action": "approve",
    })
    assert approve_resp.status_code == 200
    assert approve_resp.get_json()["status"] == "approved"

    history_resp = client.get(
        "/history?district=Galle&crop=Cinnamon&grade=Alba&limit=1")
    latest = history_resp.get_json()["data"][0]
    assert latest["date"] == "18.02.2025"
    assert latest["avg_price"] == 4900


def test_reject_request_does_not_touch_price_history(seeded_db, client):
    submit_resp = client.post("/admin/submit-price-request", json={
        "submitted_by": "test_staff",
        "district": "Galle", "crop": "Cinnamon", "grade": "Alba",
        "date": "25.02.2025", "avg_price": 9999,
    })
    request_id = submit_resp.get_json()["request_id"]

    reject_resp = client.post("/admin/review-request", json={
        "requestor_username": "admin", "request_id": request_id,
        "action": "reject", "review_note": "Price looks like a typo",
    })
    assert reject_resp.status_code == 200
    assert reject_resp.get_json()["status"] == "rejected"

    history_resp = client.get(
        "/history?district=Galle&crop=Cinnamon&grade=Alba")
    prices = [row["avg_price"] for row in history_resp.get_json()["data"]]
    assert 9999 not in prices, "a rejected request must never reach price_history"


def test_review_request_rejects_invalid_action(seeded_db, client):
    submit_resp = client.post("/admin/submit-price-request", json={
        "submitted_by": "test_staff",
        "district": "Galle", "crop": "Cinnamon", "grade": "Alba",
        "date": "01.03.2025", "avg_price": 4700,
    })
    request_id = submit_resp.get_json()["request_id"]

    resp = client.post("/admin/review-request", json={
        "requestor_username": "admin", "request_id": request_id,
        "action": "maybe",  # neither approve nor reject
    })
    assert resp.status_code == 400
