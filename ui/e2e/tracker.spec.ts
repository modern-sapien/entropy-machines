// tracker.spec.ts — an issue created through the real /api/issues endpoint
// (lib/api.py) shows up on the tracker SPA page, and its detail view
// renders what was posted.
import { test, expect, request as pwRequest, type APIRequestContext } from "@playwright/test";

const ISSUE_ID = "i-e2e-tracker-test";
const ISSUE_TITLE = "e2e tracker test issue";
const ISSUE_DESCRIPTION = "created by ui/e2e/tracker.spec.ts to verify the tracker SPA renders a real issue";

let api: APIRequestContext;

test.beforeAll(async () => {
  api = await pwRequest.newContext({
    baseURL: `http://127.0.0.1:${process.env.PW_PORT}`,
  });
  const res = await api.post("/api/issues", {
    data: { id: ISSUE_ID, title: ISSUE_TITLE, description: ISSUE_DESCRIPTION },
  });
  if (!res.ok()) {
    throw new Error(
      `tracker.spec.ts setup: POST /api/issues failed with ${res.status()}: ${await res.text()}`,
    );
  }
});

test.afterAll(async () => {
  await api.dispose();
});

test("tracker page shows an issue created via the API", async ({ page }) => {
  await page.goto("/tracker");
  await expect(page.getByRole("heading", { name: "Issues" })).toBeVisible();
  await expect(page.getByText(ISSUE_TITLE)).toBeVisible();
  await expect(page.getByText(ISSUE_ID)).toBeVisible();
});

test("issue detail shows title and description", async ({ page }) => {
  await page.goto(`/tracker/${ISSUE_ID}`);
  const detail = page.locator(".tracker-detail");
  await expect(detail.getByRole("heading", { name: ISSUE_TITLE })).toBeVisible();
  await expect(detail.getByText(ISSUE_DESCRIPTION)).toBeVisible();
});
