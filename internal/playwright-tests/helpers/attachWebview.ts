/**
 * Minimal CDP webview attachment helpers for the foundry-samples deploy
 * suite. Adapted from ai-foundry-for-vscode/playwright-tests/helpers/
 * attachWebview.ts but pared down to what this suite actually needs:
 *
 *   - Connect over CDP and find the workbench page.
 *   - Discover the playground OOPIF webview frame so we can verify the
 *     deploy succeeded by waiting for the auto-opened playground.
 *
 * VS Code webviews are out-of-process iframes (OOPIFs). Playwright cannot
 * traverse them with frameLocator chains; we connect over CDP, enable
 * Target.setAutoAttach, then iterate page.frames() looking for the inner
 * playground React frame.
 */

import type { Browser, BrowserContext, Frame, Page } from '@playwright/test';
import { chromium } from '@playwright/test';

export interface AttachedVSCode {
    browser: Browser;
    context: BrowserContext;
    mainWindow: Page;
}

export async function attachToVSCode(cdpEndpoint: string): Promise<AttachedVSCode> {
    const browser = await chromium.connectOverCDP(cdpEndpoint);
    const contexts = browser.contexts();
    if (contexts.length === 0) {
        throw new Error('No CDP contexts found on VS Code');
    }
    const context = contexts[0];
    const start = Date.now();
    let pages = context.pages();
    while (pages.length === 0 && Date.now() - start < 30_000) {
        await sleep(250);
        pages = context.pages();
    }
    const workbench = pages.find((p) => p.url().startsWith('vscode-file://')) ?? pages[0];
    if (!workbench) {
        throw new Error('No CDP pages found on VS Code');
    }

    try {
        await workbench.waitForSelector('.monaco-workbench', { state: 'attached', timeout: 60_000 });
        // eslint-disable-next-line no-console
        console.log('[attach] VS Code workbench is ready.');
    } catch (err) {
        await browser.close().catch(() => undefined);
        const pageUrls = pages.map((page) => page.url());
        throw new Error(
            `VS Code workbench did not become ready after CDP attach: ${(err as Error).message}; ` +
                `pages=${JSON.stringify(pageUrls)}`
        );
    }

    // Enable auto-attach so OOPIF webview frames are discovered on reconnect.
    try {
        const session = await workbench.context().newCDPSession(workbench);
        await session.send('Target.setAutoAttach', {
            autoAttach: true,
            waitForDebuggerOnStart: false,
            flatten: true
        });
        await sleep(500);
    } catch {
        // Best-effort — older CDP versions may not support this.
    }

    return { browser, context, mainWindow: workbench };
}

export function sleep(ms: number): Promise<void> {
    return new Promise((r) => setTimeout(r, ms));
}

/**
 * Find the playground webview frame. VS Code webviews are nested OOPIFs:
 * workbench → outer webview frame (vscode-webview://) → #active-frame inner
 * iframe. Returns the inner frame so callers can use normal Playwright
 * selectors on it.
 */
export async function findPlaygroundFrame(mainWindow: Page, timeoutMs = 30_000): Promise<Frame> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        const frames = mainWindow.frames();
        for (const f of frames) {
            if (await frameIsPlayground(f)) {
                return f;
            }
        }
        await sleep(500);
    }
    const frameUrls = mainWindow.frames().map((f) => f.url());
    throw new Error(
        `No playground webview frame found after ${timeoutMs}ms. ` +
            `${frameUrls.length} frame(s): ${frameUrls.join(' | ')}`
    );
}

async function frameIsPlayground(f: Frame): Promise<boolean> {
    try {
        return await f.evaluate(
            () =>
                !!document.querySelector('[aria-label="workflows-select"]') ||
                !!document.querySelector('[data-testid="session-details-tab-panel"]')
        );
    } catch {
        return false;
    }
}

export async function waitForPredicate(
    fn: () => Promise<boolean>,
    description: string,
    timeoutMs = 30_000,
    intervalMs = 500
): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        if (await fn()) {
            return;
        }
        await sleep(intervalMs);
    }
    throw new Error(`Timeout (${timeoutMs}ms) waiting for: ${description}`);
}

/**
 * Get the value attribute of a `<select>` element (or aria-equivalent
 * combobox text) inside the webview frame. Used to confirm the playground
 * is showing the deployed agent.
 */
export async function getWorkflowsSelectValue(frame: Frame): Promise<string | null> {
    return frame.evaluate(() => {
        const sel = document.querySelector('select[aria-label="workflows-select"]') as HTMLSelectElement | null;
        if (sel) {
            return sel.value || null;
        }
        const dropdown = document.querySelector('[role="combobox"][aria-label="workflows-select"]') as HTMLElement | null;
        return dropdown?.textContent?.trim() || null;
    });
}
