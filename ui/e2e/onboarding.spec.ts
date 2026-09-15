// onboarding.spec.ts — THE PRIORITY TEST. Walks the exact path a real new
// user hits after `bin/init` + `bin/migrate-db` + `bin/serve` (see
// global-setup.ts for how that environment gets built), and asserts the
// three onboarding bugs found in real user testing do NOT reappear:
//
//   1. manifest.json written as `{}` by bin/init -> PRD-001 never
//      registered -> dashboard shows nothing. global-setup.ts works around
//      the bug by writing a real manifest entry (same as it's filed
//      separately), and this spec asserts the doc actually shows up.
//   2. bin/init not running migrate-db -> dashboard says "API unreachable".
//      global-setup.ts runs migrate-db explicitly; this spec asserts the
//      dashboard never shows that error once it has.
//   3. An agent once guessed the PRD lives at /doc/PRD-001-orientation.html.
//      The real route, per ui/src/App.tsx, is /prds/PRD-001-orientation.
//      This spec drives the real in-app navigation (TopNav -> PRDs -> the
//      doc row) and asserts it lands there.
import { test, expect } from "@playwright/test";
import { DOC_SLUG, RESPONSE_KEY } from "./global-setup";

test("GET / returns the dashboard, not API unreachable", async ({ page }) => {
  const response = await page.goto("/");
  expect(response?.ok()).toBeTruthy();
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  await expect(page.getByText("API unreachable")).toHaveCount(0);
});

test("dashboard shows at least one registered doc (PRD-001)", async ({ page }) => {
  await page.goto("/");
  // "Docs" section lists every migrated doc with a link to it — see
  // ui/src/pages/DashboardPage.tsx. If manifest.json had been left at `{}`
  // (bug #1 above), this table would say "No docs registered yet." instead.
  await expect(page.getByRole("heading", { name: "Docs" })).toBeVisible();
  await expect(page.getByText(DOC_SLUG)).toBeVisible();
  await expect(page.getByText("No docs registered yet.")).toHaveCount(0);
});

test("clicking the PRD navigates to /prds/PRD-001-orientation", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("link", { name: "PRDs" }).click();
  await expect(page).toHaveURL(/\/prds$/);

  // The PRDs landing page (ui/src/pages/LandingPage.tsx) links each entry to
  // /prds/:slug — the real route DocPage is mounted on for PRDs. This is the
  // link an agent once guessed wrong as /doc/PRD-001-orientation.html.
  const docLink = page.locator(`a[href="/prds/${DOC_SLUG}"]`);
  await expect(docLink).toBeVisible();
  await docLink.click();
  await expect(page).toHaveURL(`/prds/${DOC_SLUG}`);
});

test("PRD page loads with response boxes visible", async ({ page }) => {
  const response = await page.goto(`/prds/${DOC_SLUG}`);
  expect(response?.ok()).toBeTruthy();
  await expect(page.getByRole("heading", { name: "PRD-001", exact: false }).first()).toBeVisible();
  const responseBoxes = page.locator("[data-resp]");
  expect(await responseBoxes.count()).toBeGreaterThan(0);
  // The specific response key this suite types into below really is on the
  // page — not just "some" response box.
  //
  // FOUND (not fixed here, out of scope for this test-setup issue): each
  // page's stored `content` (lib/migrate_db.py's extract_pages) keeps the
  // ORIGINAL <div class="response" data-resp="..."><textarea>...</textarea>
  // markup verbatim, and DocPage renders that raw HTML via
  // dangerouslySetInnerHTML *and* a second, live ResponseBox for the same
  // resp_key right after it — so every response key renders twice in the
  // DOM: one dead copy from the static doc source, one live/interactive
  // copy driven by React state. `.last()` below is the live one (it's the
  // one PageSection renders after the dangerouslySetInnerHTML block). This
  // should be filed as its own issue; migrate_db.py needs to strip response
  // divs out of page content the same way it already does for reply bodies
  // (see `_RESP_DIV_RX` usage in extract_replies).
  await expect(
    page.locator(`[data-resp="${RESPONSE_KEY}"] textarea`).last(),
  ).toBeVisible();
});

test("typing in a response box and saving persists (reload and verify)", async ({
  page,
}) => {
  await page.goto(`/prds/${DOC_SLUG}`);
  const answer = `e2e answer ${Date.now()}`;
  const textarea = page.locator(`[data-resp="${RESPONSE_KEY}"] textarea`).last();
  await textarea.fill(answer);

  const saveButton = page.getByRole("button", { name: "Save" });
  await expect(saveButton).toBeEnabled();
  const saved = page.waitForResponse(
    (res) =>
      res.url().includes(`/api/docs/${DOC_SLUG}/responses/${RESPONSE_KEY}`) &&
      res.request().method() === "PUT",
  );
  await saveButton.click();
  const saveResponse = await saved;
  expect(saveResponse.ok()).toBeTruthy();

  await page.reload();
  await expect(
    page.locator(`[data-resp="${RESPONSE_KEY}"] textarea`).last(),
  ).toHaveValue(answer);
});

test("/api/docs returns a non-empty array", async ({ request }) => {
  const res = await request.get("/api/docs");
  expect(res.ok()).toBeTruthy();
  const docs = await res.json();
  expect(Array.isArray(docs)).toBe(true);
  expect(docs.length).toBeGreaterThan(0);
  expect(docs.some((d: { id: string }) => d.id === DOC_SLUG)).toBe(true);
});
