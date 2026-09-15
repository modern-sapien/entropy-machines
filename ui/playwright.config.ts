import { defineConfig, devices } from "@playwright/test";
import { execFileSync } from "node:child_process";

// A free port, picked synchronously at config-load time the same way
// tests/lib/harness.sh's free_port() does it (bind to port 0, read it back,
// close). global-setup.ts binds bin/serve to this exact port; baseURL below
// has to agree with it, and Playwright's `use` block is fixed at config-eval
// time, before globalSetup ever runs — so the port has to be chosen here,
// not there.
const PORT = (
  process.env.PW_PORT ||
  execFileSync("python3", [
    "-c",
    'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()',
  ])
    .toString()
    .trim()
);
process.env.PW_PORT = PORT;

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  // The whole suite shares one bin/serve instance and one sqlite db (see
  // global-setup.ts) — parallel workers would race writes and step on each
  // other's issue ids, so run everything serially in one worker.
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"]],
  globalSetup: "./e2e/global-setup.ts",
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
