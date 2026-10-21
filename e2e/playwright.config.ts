import { defineConfig, devices } from "@playwright/test";

// The browser tests of Issho's page layer run against e2e/server.exs: two
// pages of a room, with Issho's people list and pointers, a block of the
// page, and an agent driven over HTTP. Its own port (4097, or E2E_PORT).
const port = Number(process.env.E2E_PORT ?? 4097);
const baseURL = `http://127.0.0.1:${port}`;

const browsers = {
  chromium: devices["Desktop Chrome"],
  firefox: devices["Desktop Firefox"],
  webkit: devices["Desktop Safari"],
};
type Browser = keyof typeof browsers;

// E2E_BROWSERS picks some of them (comma-separated); the default is all three.
const picked = (process.env.E2E_BROWSERS ?? Object.keys(browsers).join(","))
  .split(",")
  .map((name) => name.trim())
  .filter((name) => name !== "");
for (const name of picked) {
  if (!(name in browsers)) throw new Error(`E2E_BROWSERS: unknown browser "${name}", use chromium, firefox or webkit`);
}

export default defineConfig({
  testDir: "./specs",
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  reporter: "list",
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: (picked as Browser[]).map((name) => ({ name, use: { ...browsers[name] } })),
  webServer: {
    command: "mix run --no-halt e2e/server.exs",
    cwd: "..",
    url: `${baseURL}/one`,
    env: { PORT: String(port), MIX_ENV: "test" },
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
