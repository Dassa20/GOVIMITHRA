"""
locustfile.py — performance / load testing for GOVIMITHRA's backend.

SETUP:
    pip install locust --break-system-packages

RUN (against your REAL running backend, not the live-test one):
    cd backend/
    python app.py                        # in one terminal, real server
    locust -f locustfile.py --host=http://127.0.0.1:5000   # in another

Then open http://localhost:8089 in a browser — Locust's own web UI
lets you set the number of simulated users and spawn rate, then shows
live response-time graphs, failure rates, and requests/second as the
test runs. This is the standard, industry-normal way to load-test a
Flask API — no custom dashboard needed.

FIX applied after a real run showed 96% failures with a suspiciously
uniform ~2000ms across every endpoint — including /health, which is
just a static JSON response with no database or model involved.
That uniformity, on the SIMPLEST possible endpoint, pointed to a
silent client-side timeout rather than genuine server slowness (real
server contention shows up as varied, climbing times, not a razor-
sharp identical ceiling everywhere). Every request below now passes
an explicit, generous timeout=30 — if failures persist with THIS in
place, the response times shown will be genuinely meaningful (how
long things actually took before failing), rather than an ambiguous
flat number that could mean almost anything.

WHAT THIS TESTS:
- How response times behave as concurrent farmer requests increase
  (10, 50, 100 simulated users hitting /predict, /metadata, /history
  at once — simulating many farmers using the app during a peak
  price-check period, e.g. right before a market day)
- Whether the app degrades gracefully (slower but still correct)
  or starts failing/erroring under load
- A realistic MIX of endpoints, weighted by how often the real app
  actually calls them (metadata + weather are more frequent than
  predict, since predict is a deliberate farmer action)

WHAT TO LOOK FOR IN THE RESULTS:
- p95 (95th percentile) response time — the number quoted in
  Non-Functional Testing sections; average alone hides bad outliers
- Failure rate — should stay at 0% up to a documented threshold of
  concurrent users, so you can honestly state "the app handles N
  concurrent farmers without errors" with real evidence
- Where response times start climbing sharply — that's your
  practical concurrency ceiling for this deployment
- If failures reappear: click the FAILURES tab for the exact error
  text (e.g. ConnectionError vs a real 500) before assuming a cause

IMPORTANT — Flask's dev server has real, known concurrency limits:
app.py's own startup banner says this directly: "This is a
development server... Use a production WSGI server instead." If
failures persist even with a generous timeout, that's likely a
genuine finding about this specific server's practical concurrency
ceiling, not a bug in this test file — worth documenting as-is, and
worth re-testing with fewer simulated users (e.g. 10, then 20, then
50) to find exactly where failures start appearing.
"""
from locust import HttpUser, task, between
import random

DISTRICTS_CROPS = [
    ("Galle", "Cinnamon", "Alba"),
    ("Matara", "Cinnamon", "Alba"),
    ("Kandy", "Pepper", "GR-1"),
    ("Matale", "Pepper", "GR-1"),
]

REQUEST_TIMEOUT = 30  # seconds — generous, so real slowness is visible
                       # rather than an ambiguous silent cutoff


class FarmerUser(HttpUser):
    """
    Simulates a single farmer's typical session: check the weather,
    look at metadata (available crops/districts), then request a
    price prediction — roughly the real usage pattern of the app,
    not just hammering one endpoint in isolation.
    """
    wait_time = between(1, 3)  # seconds between actions, like a real user

    @task(3)
    def check_metadata(self):
        """Most frequent call — happens on every Home screen load."""
        self.client.get("/metadata", name="/metadata", timeout=REQUEST_TIMEOUT)

    @task(3)
    def check_health(self):
        """Frequent, lightweight — used for connectivity checks."""
        self.client.get("/health", name="/health", timeout=REQUEST_TIMEOUT)

    @task(2)
    def get_history(self):
        district, crop, grade = random.choice(DISTRICTS_CROPS)
        self.client.get(
            f"/history?district={district}&crop={crop}&grade={grade}&limit=16",
            name="/history",
            timeout=REQUEST_TIMEOUT,
        )

    @task(1)
    def get_prediction(self):
        """
        Rarer, deliberate action — a farmer explicitly asking "what
        will my price be this week", not something that fires on
        every screen load, hence the lower weight relative to
        metadata/health above.
        """
        district, crop, grade = random.choice(DISTRICTS_CROPS)
        self.client.post(
            "/predict",
            json={"district": district, "crop": crop, "grade": grade},
            name="/predict",
            timeout=REQUEST_TIMEOUT,
        )

    @task(1)
    def get_harvest_status(self):
        district, crop, _ = random.choice(DISTRICTS_CROPS)
        self.client.post(
            "/harvest-status",
            json={"district": district, "crop": crop},
            name="/harvest-status",
            timeout=REQUEST_TIMEOUT,
        )


class AdminUser(HttpUser):
    """
    A much smaller, separate population — DEA staff checking the
    price table, not farmers. Locust runs both user classes together
    automatically, weighted by their relative population (see
    weight= below), giving a realistic mixed-traffic simulation
    rather than testing farmer and admin load in isolation.
    """
    wait_time = between(2, 5)
    weight = 1  # much rarer than FarmerUser in the simulated population

    @task
    def check_price_table(self):
        self.client.get(
            "/history?district=Galle&crop=Cinnamon&grade=Alba&limit=50",
            name="/history (admin, larger page)",
            timeout=REQUEST_TIMEOUT,
        )


# Give farmers a much larger share of simulated traffic than admin
# staff, matching the real expected usage pattern.
FarmerUser.weight = 20
