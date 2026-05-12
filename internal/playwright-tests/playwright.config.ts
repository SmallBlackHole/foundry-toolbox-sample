import { defineConfig } from '@playwright/test';

/**
 * Each sample takes several minutes to build + push + deploy. Playwright's
 * per-test timeout is therefore generous, and we keep `workers: 1` to avoid
 * concurrent ACR pushes / Docker daemon contention.
 *
 * Filter which samples run with `FOUNDRY_SAMPLES_INCLUDE` (regex) and
 * `FOUNDRY_SAMPLES_EXCLUDE` (regex). See specs/deploySamples.spec.ts.
 */
export default defineConfig({
    testDir: './specs',
    timeout: 30 * 60_000, // 30 min per sample (Docker build + ACR push + deploy)
    expect: { timeout: 30_000 },
    fullyParallel: false,
    workers: 1,
    retries: 0,
    reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
    globalSetup: './fixtures/globalSetup.ts',
    use: {
        actionTimeout: 15_000,
        trace: 'retain-on-failure',
        video: 'retain-on-failure'
    },
    projects: [
        {
            name: 'python-hosted-agents',
            grep: /\[python\]/
        },
        {
            name: 'csharp-hosted-agents',
            grep: /\[csharp\]/
        }
    ]
});
