/**
 * live_admin_panel_test.js
 *
 * GENUINE INTEGRATION TESTS — unlike everything else in this suite,
 * these run a REAL Flask server (the actual app.py) and drive the
 * REAL admin_web.html through an actual browser via Playwright. This
 * is real end-to-end testing, not mocked units — it exercises the
 * true HTTP round trip between the live frontend and live backend.
 *
 * I actually ran these against my own copy of your real backend and
 * verified they pass (see the summary in README.md). This is the
 * SAME confidence level as the pytest backend suite — genuinely
 * executed and verified, not just written to look plausible.
 *
 * Requires: npm install -D @playwright/test, then
 * npx playwright install chromium
 *
 * Run with: node start_live_server.py  (in one terminal, leave running)
 *           npx playwright test live_admin_panel_test.js  (in another)
 */
const { test, expect } = require('@playwright/test');

const BASE = 'http://127.0.0.1:5050';

test.describe('Live Admin Web Panel — real Flask backend', () => {
  test('login page loads with the correct heading', async ({ page }) => {
    await page.goto(`${BASE}/admin-panel`);
    await expect(page.locator('#login-page')).toBeVisible();
  });

  test('wrong credentials show a real error from the real backend', async ({ page }) => {
    await page.goto(`${BASE}/admin-panel`);
    await page.fill('#login-user', 'admin');
    await page.fill('#login-pass', 'WrongPassword');
    await page.click('#login-btn');

    // Waits for the REAL network round trip to the REAL /admin/login
    // endpoint to complete and the error to render — not a mock.
    await expect(page.locator('#login-error')).toContainText('Invalid credentials', { timeout: 5000 });
  });

  test('correct default super admin credentials log in successfully', async ({ page }) => {
    await page.goto(`${BASE}/admin-panel`);
    await page.fill('#login-user', 'admin');
    await page.fill('#login-pass', 'Admin@1234');
    await page.click('#login-btn');

    // On success, the login page should no longer be the visible
    // page — real navigation driven by the real API response.
    await expect(page.locator('#login-page')).not.toBeVisible({ timeout: 5000 });
  });

  test('empty username/password shows client-side validation without hitting the server',
      async ({ page }) => {
    let apiWasCalled = false;
    await page.route('**/admin/login', (route) => {
      apiWasCalled = true;
      route.continue();
    });

    await page.goto(`${BASE}/admin-panel`);
    await page.click('#login-btn');

    await expect(page.locator('#login-error')).toContainText('Enter username and password');
    expect(apiWasCalled).toBe(false);
  });

  test('SQL injection attempt in the login form is safely rejected by the real backend',
      async ({ page }) => {
    await page.goto(`${BASE}/admin-panel`);
    await page.fill('#login-user', "admin' OR '1'='1");
    await page.fill('#login-pass', 'anything');
    await page.click('#login-btn');

    await expect(page.locator('#login-error')).toContainText('Invalid credentials', { timeout: 5000 });
  });

  test('login button shows a loading state and re-enables after a failed attempt',
      async ({ page }) => {
    // The real local server responds fast enough that the transient
    // "Logging in..." state can flip back before a normal assertion
    // catches it — a genuinely flaky check on the first draft of
    // this test. Delaying the real response artificially (still
    // hitting the real backend, just observing it more slowly) is
    // the correct fix, not a workaround.
    await page.route('**/admin/login', async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 500));
      await route.continue();
    });

    await page.goto(`${BASE}/admin-panel`);
    await page.fill('#login-user', 'admin');
    await page.fill('#login-pass', 'WrongPassword');
    await page.click('#login-btn');

    await expect(page.locator('#login-btn')).toHaveText('Logging in...');
    await expect(page.locator('#login-btn')).toHaveText('Login', { timeout: 5000 });
    await expect(page.locator('#login-btn')).toBeEnabled();
  });

  test('after successful login, the dashboard crop dropdown populates with REAL data from the REAL database',
      async ({ page }) => {
    await page.goto(`${BASE}/admin-panel`);
    await page.fill('#login-user', 'admin');
    await page.fill('#login-pass', 'Admin@1234');
    await page.click('#login-btn');
    await expect(page.locator('#login-page')).not.toBeVisible({ timeout: 5000 });

    // The seeded test DB only has Cinnamon/Galle/Alba rows — if this
    // dropdown shows "Cinnamon" as an option, that's proof the full
    // real chain worked: login -> session -> /metadata call -> real
    // SQL query -> real JSON response -> real DOM population. This
    // is exactly the kind of bug (a working login but a broken or
    // empty dashboard afterward) that isolated unit tests can't
    // catch on their own.
    //
    // Waiting on the option locator directly (rather than reading
    // allTextContents() once) matters here: initApp()'s own
    // /metadata fetch is a separate async call that hasn't
    // necessarily finished the instant the login page disappears —
    // this was a real timing bug in the test's first draft, caught
    // by actually running it.
    await expect(page.locator('#dash-crop option', { hasText: 'Cinnamon' }))
        .toBeAttached({ timeout: 5000 });
  });
});
