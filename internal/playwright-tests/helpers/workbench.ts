/**
 * Workbench-level helpers: run a VS Code command and interact with Quick Picks
 * via keyboard. These operate on the main workbench Page (NOT the webview
 * frame).
 *
 * Adapted from ai-foundry-for-vscode/playwright-tests/helpers/workbench.ts.
 */

import type { Page } from '@playwright/test';
import * as path from 'node:path';
import { sleep } from './attachWebview';

function screenshotName(commandTitle: string): string {
    return `command-palette-${commandTitle
        .replace(/[^a-z0-9]+/gi, '-')
        .replace(/^-|-$/g, '')
        .slice(0, 80)}.png`;
}

export async function runCommand(mainWindow: Page, commandTitle: string): Promise<void> {
    await mainWindow.bringToFront();
    await mainWindow.keyboard.press('Escape');
    await sleep(200);
    await openCommandPalette(mainWindow, commandTitle);

    const input = mainWindow.locator('.quick-input-widget input').first();
    await input.waitFor({ state: 'visible', timeout: 10_000 });
    await input.fill(`>${commandTitle}`);
    await mainWindow.waitForFunction(
        (title: string) => {
            const el = document.querySelector('.quick-input-widget input') as HTMLInputElement | null;
            return el?.value === `>${title}`;
        },
        commandTitle,
        { timeout: 10_000 }
    );
    await sleep(500);

    const rows = await mainWindow.evaluate(() => {
        const widget = document.querySelector('.quick-input-widget');
        return Array.from(widget?.querySelectorAll('.monaco-list-row') ?? [])
            .map((row) => ({
                ariaLabel: row.getAttribute('aria-label') ?? '',
                text: (row.textContent ?? '').replace(/\s+/g, ' ').trim(),
                rect: (() => {
                    const rect = row.getBoundingClientRect();
                    return {
                        x: rect.left + rect.width / 2,
                        y: rect.top + rect.height / 2,
                        width: rect.width,
                        height: rect.height
                    };
                })()
            }))
            .filter((row) => row.text.length > 0 || row.ariaLabel.length > 0)
            .slice(0, 8);
    });
    const firstRow = rows[0];
    if (firstRow && (firstRow.ariaLabel.startsWith(commandTitle) || firstRow.text.includes(commandTitle))) {
        const activationAttempts: Array<() => Promise<void>> = [
            async () => {
                await input.focus();
                await input.press('Enter');
            },
            () => mainWindow.keyboard.press('Enter')
        ];
        if (firstRow.rect.width > 0 && firstRow.rect.height > 0) {
            activationAttempts.push(() => mainWindow.mouse.dblclick(firstRow.rect.x, firstRow.rect.y));
        }

        for (const attempt of activationAttempts) {
            await attempt();
            if (await waitForStableCommandAdvance(mainWindow, commandTitle, 8_000)) {
                await sleep(1_000);
                if (!(await commandPaletteStillShowing(mainWindow, commandTitle))) {
                    return;
                }
            }
        }
    } else {
        const snapshot = await mainWindow.evaluate(() => {
            const widget = document.querySelector('.quick-input-widget');
            const input = widget?.querySelector('input') as HTMLInputElement | null;
            return {
                placeholder: input?.placeholder ?? '',
                value: input?.value ?? '',
                rows: Array.from(widget?.querySelectorAll('.monaco-list-row') ?? [])
                    .map((row) => ({
                        ariaLabel: row.getAttribute('aria-label'),
                        text: (row.textContent ?? '').replace(/\s+/g, ' ').trim()
                    }))
                    .slice(0, 8)
            };
        });
        await mainWindow.screenshot({ path: path.join('test-results', screenshotName(commandTitle)), fullPage: true });
        throw new Error(`Command "${commandTitle}" was not the first Quick Pick result: ${JSON.stringify(snapshot)}`);
    }

    if (await commandPaletteStillShowing(mainWindow, commandTitle)) {
        await mainWindow.screenshot({ path: path.join('test-results', screenshotName(commandTitle)), fullPage: true });
        const snapshot = await mainWindow.evaluate(() => {
            const widget = document.querySelector('.quick-input-widget');
            const input = widget?.querySelector('input') as HTMLInputElement | null;
            return {
                title: (widget?.querySelector('.quick-input-title')?.textContent ?? '').trim(),
                placeholder: input?.placeholder ?? '',
                value: input?.value ?? '',
                rows: Array.from(widget?.querySelectorAll('.monaco-list-row') ?? [])
                    .map((row) => ({
                        ariaLabel: row.getAttribute('aria-label'),
                        text: (row.textContent ?? '').replace(/\s+/g, ' ').trim()
                    }))
                    .slice(0, 8)
            };
        });
        throw new Error(`Command "${commandTitle}" did not execute from Quick Pick: ${JSON.stringify(snapshot)}`);
    }

    await sleep(1_000);
}

async function openCommandPalette(mainWindow: Page, diagnosticName: string): Promise<void> {
    const modKey = process.platform === 'darwin' ? 'Meta' : 'Control';
    const attempts = ['F1', `${modKey}+Shift+KeyP`, 'F1'];

    for (const shortcut of attempts) {
        await mainWindow.bringToFront();
        await mainWindow.mouse.click(20, 20).catch(() => {});
        await mainWindow.keyboard.press('Escape').catch(() => {});
        await sleep(150);
        await mainWindow.keyboard.press(shortcut);
        try {
            await waitForQuickPick(mainWindow, 3_000);
            return;
        } catch {
            // Try the next shortcut before failing with diagnostics.
        }
    }

    await mainWindow.screenshot({
        path: path.join('test-results', screenshotName(`open-${diagnosticName}`)),
        fullPage: true
    });
    const snapshot = await mainWindow.evaluate(() => {
        const active = document.activeElement as HTMLElement | null;
        return {
            title: document.title,
            activeTag: active?.tagName,
            activeClass: active?.className?.toString(),
            activeAriaLabel: active?.getAttribute('aria-label'),
            quickPickExists: !!document.querySelector('.quick-input-widget')
        };
    });
    throw new Error(`Command palette did not open for "${diagnosticName}": ${JSON.stringify(snapshot)}`);
}

async function waitForStableCommandAdvance(
    mainWindow: Page,
    commandTitle: string,
    timeoutMs: number
): Promise<boolean> {
    const start = Date.now();
    let stableCount = 0;
    while (Date.now() - start < timeoutMs) {
        if (await commandPaletteStillShowing(mainWindow, commandTitle)) {
            stableCount = 0;
        } else {
            stableCount++;
            if (stableCount >= 10) {
                return true;
            }
        }
        await sleep(250);
    }
    return false;
}

async function commandPaletteStillShowing(mainWindow: Page, commandTitle: string): Promise<boolean> {
    return mainWindow.evaluate((title: string) => {
        const widget = document.querySelector('.quick-input-widget') as HTMLElement | null;
        const input = widget?.querySelector('input') as HTMLInputElement | null;
        if (!widget || widget.style.display === 'none') {
            return false;
        }
        return input?.placeholder === 'Type the name of a command to run.' && input.value === `>${title}`;
    }, commandTitle);
}

export async function quickPickAccept(mainWindow: Page): Promise<void> {
    const firstVisibleRow = await mainWindow.evaluate(() => {
        const rows = Array.from(document.querySelectorAll('.quick-input-widget .monaco-list-row')) as HTMLElement[];
        const row = rows.find((candidate) => {
            const rect = candidate.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && (candidate.textContent ?? '').trim().length > 0;
        });
        if (!row) {
            return undefined;
        }
        const rect = row.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    });
    if (firstVisibleRow) {
        await mainWindow.mouse.click(firstVisibleRow.x, firstVisibleRow.y);
    } else {
        await mainWindow.keyboard.press('Enter');
    }
    await sleep(500);
}

export async function waitForQuickPick(mainWindow: Page, timeoutMs = 10_000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        const visible = await mainWindow.evaluate(() => {
            const el = document.querySelector('.quick-input-widget');
            if (!el) {
                return false;
            }
            const style = (el as HTMLElement).style;
            return style.display !== 'none';
        });
        if (visible) {
            return;
        }
        await sleep(200);
    }
    throw new Error(`Quick pick did not appear within ${timeoutMs}ms`);
}

export async function waitForQuickPickHidden(mainWindow: Page, timeoutMs = 10_000): Promise<void> {
    const start = Date.now();
    let hiddenSince = 0;
    while (Date.now() - start < timeoutMs) {
        const hidden = await quickPickIsHidden(mainWindow);
        if (hidden) {
            hiddenSince = hiddenSince || Date.now();
            if (Date.now() - hiddenSince >= 1_000) {
                return;
            }
        } else {
            hiddenSince = 0;
        }
        await sleep(200);
    }
    throw new Error(`Quick pick did not stay hidden within ${timeoutMs}ms`);
}

export async function waitForQuickPickItems(mainWindow: Page, timeoutMs = 30_000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        const hasItems = await mainWindow.evaluate(() => {
            const widget = document.querySelector('.quick-input-widget');
            if (!widget || (widget as HTMLElement).style.display === 'none') {
                return false;
            }
            const rows = widget.querySelectorAll('.monaco-list-row');
            return rows.length > 0;
        });
        if (hasItems) {
            return;
        }
        await sleep(300);
    }
    throw new Error(`Quick pick items did not load within ${timeoutMs}ms`);
}

export async function quickPickIsHidden(mainWindow: Page): Promise<boolean> {
    return mainWindow.evaluate(() => {
        const el = document.querySelector('.quick-input-widget') as HTMLElement | null;
        if (!el) {
            return true;
        }
        return el.style.display === 'none';
    });
}

export async function closeAllEditors(mainWindow: Page): Promise<void> {
    await runCommand(mainWindow, 'View: Close All Editors');
    await sleep(1_500);
}

/**
 * Snapshot the visible workbench state — useful for diagnostics when a
 * Quick Pick or command sequence stalls. Mirrors the diagnostic helpers
 * used in the ai-foundry-for-vscode deploy spec.
 */
export async function workbenchSnapshot(mainWindow: Page): Promise<{
    title: string;
    quickPick: { title: string; placeholder: string; value: string; items: string[] };
    notifications: string[];
    progressText: string;
    outputText: string;
    panelText: string;
    editorText: string;
}> {
    return mainWindow.evaluate(() => {
        const normalizeLines = (value: string): string =>
            value
                .replace(/\r/g, '')
                .split('\n')
                .map((line) => line.replace(/\s+/g, ' ').trim())
                .filter(Boolean)
                .join('\n');
        const tail = (value: string, maxLength = 8_000): string =>
            value.length > maxLength ? value.slice(value.length - maxLength) : value;
        const visibleText = (selector: string): string =>
            tail(
                Array.from(document.querySelectorAll(selector))
                    .map((el) => normalizeLines(el.textContent ?? ''))
                    .filter(Boolean)
                    .join('\n')
            );

        const widget = document.querySelector('.quick-input-widget') as HTMLElement | null;
        const input = widget?.querySelector('input') as HTMLInputElement | null;
        const quickPick = {
            title: (widget?.querySelector('.quick-input-title')?.textContent ?? '').trim(),
            placeholder: input?.placeholder ?? '',
            value: input?.value ?? '',
            items: Array.from(widget?.querySelectorAll('.monaco-list-row') ?? [])
                .map((row) => (row.textContent ?? '').replace(/\s+/g, ' ').trim())
                .filter(Boolean)
                .slice(0, 8)
        };
        return {
            title: document.title,
            quickPick,
            notifications: Array.from(
                document.querySelectorAll('.notification-list-item, .monaco-list-row.notification-list-item')
            )
                .map((el) => (el.textContent ?? '').replace(/\s+/g, ' ').trim())
                .filter(Boolean)
                .slice(0, 8),
            progressText: Array.from(
                document.querySelectorAll('.progress-container, .monaco-progress-container, .progress-badge')
            )
                .map((el) => (el.textContent ?? '').replace(/\s+/g, ' ').trim())
                .filter(Boolean)
                .join(' | '),
            outputText: visibleText('.output-view .view-line, .part.panel .output-view .monaco-editor .view-line'),
            panelText: visibleText('.part.panel'),
            editorText: (document.querySelector('.editor .title-label, .tabs-container')?.textContent ?? '')
                .replace(/\s+/g, ' ')
                .trim()
        };
    });
}
