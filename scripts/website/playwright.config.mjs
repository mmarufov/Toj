import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  testDir: './tests', fullyParallel: true, workers: process.env.CI ? 2 : 3,
  timeout: 30000, expect: { timeout: 5000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: { baseURL: process.env.SITE_URL || 'http://127.0.0.1:4173', trace: 'retain-on-failure' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 1100 } } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'], viewport: { width: 1440, height: 1100 } } },
    { name: 'webkit', use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 1100 } } },
  ],
  webServer: process.env.SITE_URL ? undefined : { command: 'node serve.mjs', url: 'http://127.0.0.1:4173', reuseExistingServer: !process.env.CI },
});
