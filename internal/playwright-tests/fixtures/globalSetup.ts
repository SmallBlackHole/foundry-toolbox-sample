/**
 * Playwright global setup / teardown.
 *
 * Each test in this suite launches its OWN VS Code instance (because the
 * deploy flow uses workspace.workspaceFolders[0] as the agent root, so we
 * need a fresh per-test workspace). Global setup therefore only handles
 * fixture configuration and pre-run / post-run cleanup of leftover agents.
 */

import type { FullConfig } from '@playwright/test';
import { ensureFixtureConfigured } from './configPrompt';
import { clearTracker } from '../helpers/sessionTracker';
import { cleanupTrackedArtefacts } from './sessionTeardown';

export default async function globalSetup(_config: FullConfig): Promise<() => Promise<void>> {
    await ensureFixtureConfigured();

    // Clean up leftovers from a prior aborted run BEFORE wiping the tracker.
    try {
        await cleanupTrackedArtefacts();
    } catch (err) {
        // eslint-disable-next-line no-console
        console.warn('[setup] Pre-run cleanup of stale artefacts failed:', (err as Error).message);
    }
    clearTracker();

    return async () => {
        try {
            await cleanupTrackedArtefacts();
        } catch (err) {
            // eslint-disable-next-line no-console
            console.warn('[teardown] cleanupTrackedArtefacts failed:', (err as Error).message);
        }
    };
}
