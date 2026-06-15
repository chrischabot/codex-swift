import { defineConfig } from "@playwright/test";

// E2E drives the REAL built app (mock connector via VITE_CONNECTOR=mock) so the
// whole render → connector → tab → live-job-log path is exercised front-to-back.
// The mock connector streams scripted wiki/job events, mirroring the live WS path.
export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  retries: 0,
  reporter: [["list"]],
  use: { baseURL: "http://127.0.0.1:4173", headless: true },
  webServer: {
    command: "VITE_CONNECTOR=mock npm run build && npx vite preview --port 4173 --host 127.0.0.1 --strictPort",
    url: "http://127.0.0.1:4173",
    timeout: 180_000,
    reuseExistingServer: true,
  },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
});
