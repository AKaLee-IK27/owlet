import { test, expect } from "@playwright/test";

const SECTIONS = ["hero", "how-it-works", "privacy", "apps", "modes", "download"];

test("has exactly one h1", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1")).toHaveCount(1);
});

test("all six sections render", async ({ page }) => {
  await page.goto("/");
  for (const id of SECTIONS) {
    await expect(page.locator(`#${id}`)).toBeVisible();
  }
});

test("no em-dashes anywhere in visible text (skill ban)", async ({ page }) => {
  await page.goto("/");
  const body = await page.locator("body").innerText();
  expect(body.includes("—")).toBe(false);
});

test("no em-dash in document title metadata (skill ban is total)", async ({ page }) => {
  await page.goto("/");
  const title = await page.title();
  expect(title.includes("—")).toBe(false);
});

test("every image has non-empty alt or explicit empty decorative alt", async ({ page }) => {
  await page.goto("/");
  const imgs = page.locator("img");
  const count = await imgs.count();
  expect(count).toBeGreaterThan(0);
  for (let i = 0; i < count; i++) {
    const alt = await imgs.nth(i).getAttribute("alt");
    expect(alt).not.toBeNull();
  }
});
