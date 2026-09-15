// settings.spec.ts — the theme selector (ui/src/components/SettingsModal.tsx
// + ThemeSelector.tsx) is reachable from the top nav and its choice survives
// a reload. Theme is stored in localStorage (see ui/src/data/themes.ts and
// the inline pre-paint script in ui/index.html), not the /api/settings
// endpoint — this spec verifies the actual persistence mechanism the app
// uses, not an assumed one.
import { test, expect } from "@playwright/test";

test("settings/theme selector is accessible", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".theme-selector")).toHaveCount(0);

  await page.getByTitle("Settings").click();
  const selector = page.getByTitle("Theme");
  await expect(selector).toBeVisible();

  // All five themes from ui/src/data/themes.ts are offered.
  const options = await selector.locator("option").allTextContents();
  expect(options.length).toBe(5);
});

test("changing a theme persists across reload", async ({ page }) => {
  await page.goto("/");
  await page.getByTitle("Settings").click();
  const selector = page.getByTitle("Theme");
  await expect(selector).toBeVisible();

  const before = await selector.inputValue();
  const target = before === "hc-dark" ? "daylight" : "hc-dark";
  await selector.selectOption(target);
  await expect(selector).toHaveValue(target);

  // Applied immediately, before any reload — style.setProperty writes
  // straight onto <html>.
  const accentBefore = await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue("--accent").trim(),
  );
  expect(accentBefore.length).toBeGreaterThan(0);

  await page.reload();

  // Persisted via localStorage + the pre-paint script in index.html — the
  // theme should already be applied before we even reopen the modal.
  const accentAfter = await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue("--accent").trim(),
  );
  expect(accentAfter).toBe(accentBefore);

  const storedTheme = await page.evaluate(() =>
    localStorage.getItem("entropy-machines-theme"),
  );
  expect(storedTheme).toBe(target);

  await page.getByTitle("Settings").click();
  await expect(page.getByTitle("Theme")).toHaveValue(target);
});
