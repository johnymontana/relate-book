import { defineConfig } from '@playwright/test';

const DEV_PORT = 5184;
const BUILD_PORT = 5186;

// End-to-end tests run in the installed Chrome (no browser download) and need
// no network, no GPU and no model download:
// - `app.spec.ts` drives the dev server with the bundled sample and `?stub-ai`;
// - `build.spec.ts` drives the production build (`vite build`, then
//   `vite preview`), because asset, worker and dataset URLs resolve
//   differently there.
export default defineConfig({
  testDir: 'e2e',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    channel: 'chrome',
    viewport: { width: 1400, height: 900 },
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'dev', testMatch: 'app.spec.ts', use: { baseURL: `http://localhost:${DEV_PORT}` } },
    // Served under a sub-path, the way a static host (GitHub Pages) would.
    { name: 'build', testMatch: 'build.spec.ts', use: { baseURL: `http://localhost:${BUILD_PORT}/relate-books/` } },
  ],
  webServer: [
    {
      command: `npx vite --port ${DEV_PORT} --strictPort`,
      url: `http://localhost:${DEV_PORT}`,
      reuseExistingServer: false,
      timeout: 60_000,
    },
    {
      command: `npx vite build --base /relate-books/ --outDir dist-e2e && npx vite preview --base /relate-books/ --outDir dist-e2e --port ${BUILD_PORT} --strictPort`,
      url: `http://localhost:${BUILD_PORT}/relate-books/`,
      reuseExistingServer: false,
      timeout: 120_000,
    },
  ],
});
