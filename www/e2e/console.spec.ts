import { test, expect } from "@playwright/test";

// Front-to-back E2E of the Memory Wiki Console against the mock connector (which
// streams scripted wiki/job events just like the live WS path). Drives the real
// built app in a real browser.

test.beforeEach(async ({ page }) => {
  await page.goto("/wiki/console");
  await expect(page.getByRole("tab", { name: "Search", exact: true })).toBeVisible();
});

test("Research tab streams live progress to a terminal result", async ({ page }) => {
  await page.getByRole("tab", { name: "Research", exact: true }).click();
  await page.getByLabel("research input").fill("graph neural networks");
  await page.getByRole("button", { name: /^research$/i }).click();

  // The streamed NDJSON lines render in the live log, in order.
  await expect(page.getByText(/research started/)).toBeVisible();
  await expect(page.getByText(/3 source\(s\) gathered/)).toBeVisible();
  await expect(page.getByText(/2 written, 8 claims/)).toBeVisible();
  await expect(page.getByText(/round 1 done — score 44/)).toBeVisible();
  await expect(page.getByText(/✓ completed — 1 round\(s\), 3 sources, 2 pages, score 44/)).toBeVisible();
});

test("Ingest tab streams per-candidate progress", async ({ page }) => {
  await page.getByRole("tab", { name: "Ingest", exact: true }).click();
  await page.getByLabel("ingest input").fill("https://github.com/openai");
  await page.getByRole("button", { name: /^ingest$/i }).click();

  await expect(page.getByText(/\[1\] written/)).toBeVisible();
  await expect(page.getByText(/\[2\] written/)).toBeVisible();
  await expect(page.getByText(/✓ done — 2 written/)).toBeVisible();
});

test("Search tab returns hits", async ({ page }) => {
  await page.getByLabel("Search query").fill("vector databases");
  await page.getByRole("button", { name: /^search$/i }).click();
  await expect(page.getByText(/Result for/)).toBeVisible();
  await expect(page.getByText("Vector Databases", { exact: true })).toBeVisible();
});

test("Status tab shows the dashboard", async ({ page }) => {
  await page.getByRole("tab", { name: "Status", exact: true }).click();
  await expect(page.getByText("4,986")).toBeVisible();
  await expect(page.getByText("Raw documents")).toBeVisible();
});

test("Watch tab lists watched sources", async ({ page }) => {
  await page.getByRole("tab", { name: "Watch", exact: true }).click();
  await expect(page.getByText("https://github.com/openai")).toBeVisible();
  await expect(page.getByText("due now")).toBeVisible();
});
