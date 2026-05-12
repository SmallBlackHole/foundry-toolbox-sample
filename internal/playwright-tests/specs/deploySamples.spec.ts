/**
 * deploySamples.spec.ts — validates that every hosted-agent sample under
 * `samples/python/hosted-agents/**` and `samples/csharp/hosted-agents/**`
 * deploys cleanly via the AI Foundry VS Code extension.
 *
 * Per sample, the test:
 *   1. Copies the sample directory into an empty per-test temp workspace.
 *   2. Rewrites `name:` in agent.yaml to a unique `pw-` prefixed value so
 *      runs don't collide with each other or with shared deployments.
 *   3. Launches its own VS Code instance with that workspace folder.
 *   4. Records the deterministic agent name in the tracker BEFORE deploying
 *      so global teardown can clean up even if the deploy fails partway.
 *   5. Runs the `azure-ai-foundry.commandPalette.deployWorkflow` command
 *      (surfaced in the palette as `Microsoft Foundry: Deploy Hosted
 *      Agent`), accepting Quick Pick defaults at every step.
 *   6. Verifies the playground auto-opens and shows the deployed agent.
 *   7. Calls the deployed endpoint through its declared API protocol.
 *   8. Quits VS Code and removes the temp workspace.
 *
 * The spec runs serially (workers: 1, fullyParallel: false) because Docker
 * builds and ACR pushes contend for the same daemon and credentials.
 *
 * Filter which samples run with FOUNDRY_SAMPLES_INCLUDE / EXCLUDE regexes.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { test, expect } from '@playwright/test';
import type { Frame, Page } from '@playwright/test';
import {
    attachToVSCode,
    findPlaygroundFrame,
    getWorkflowsSelectValue,
    sleep,
    waitForPredicate
} from '../helpers/attachWebview';
import { launchVSCode, type LaunchedVSCode } from '../fixtures/vscodeLauncher';
import { createSampleWorkspace, removeSampleWorkspace, rewriteAgentName } from '../fixtures/tempWorkspace';
import { recordDeployedAgent } from '../helpers/sessionTracker';
import { readHostedAgentProtocols, smokeTestDeployedAgentApis } from '../helpers/agentApiSmoke';
import {
    quickPickAccept,
    runCommand,
    waitForQuickPick,
    workbenchSnapshot,
    closeAllEditors
} from '../helpers/workbench';
import { discoverSamples, type SampleDescriptor } from '../helpers/sampleDiscovery';

const DEFAULT_DEPLOY_CDP_PORT = Number(process.env.AI_FOUNDRY_PLAYWRIGHT_CDP_PORT ?? 9233);

// Command we exercise. The command palette filters by the localized title
// (category + title), but the underlying contract is the command ID below.
// If the title ever changes upstream, update DEPLOY_COMMAND_TITLE only.
//   id:    azure-ai-foundry.commandPalette.deployWorkflow
//   title: Deploy Hosted Agent (category: Microsoft Foundry)
const DEPLOY_COMMAND_ID = 'azure-ai-foundry.commandPalette.deployWorkflow';
const DEPLOY_COMMAND_TITLE = 'Microsoft Foundry: Deploy Hosted Agent';

function deterministicAgentName(sample: SampleDescriptor, index: number): string {
    // Names must be alphanumeric + dashes per agent-name validation. Keep them
    // short so they fit comfortably in API URLs and registry tags.
    const stamp = new Date()
        .toISOString()
        .replace(/[^0-9]/g, '')
        .slice(0, 14);
    const slug = sample.displayName
        .replace(/[^a-zA-Z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .toLowerCase()
        .slice(0, 28);
    return `pw-${sample.language}-${slug}-${stamp}${index}`;
}

async function playgroundIsOpen(mainWindow: Page): Promise<boolean> {
    try {
        await findPlaygroundFrame(mainWindow, 1_000);
        return true;
    } catch {
        return false;
    }
}

type QuickInputState = {
    title: string;
    placeholder: string;
    hasInput: boolean;
    rowCount: number;
};

async function visibleQuickInputState(mainWindow: Page): Promise<QuickInputState> {
    return mainWindow.evaluate(() => {
        const widget = document.querySelector('.quick-input-widget') as HTMLElement | null;
        if (!widget || widget.style.display === 'none') {
            return { title: '', placeholder: '', hasInput: false, rowCount: 0 };
        }

        const input = widget.querySelector('input') as HTMLInputElement | null;
        const rows = Array.from(widget.querySelectorAll('.monaco-list-row')) as HTMLElement[];
        const visibleRows = rows.filter((candidate) => {
            const rect = candidate.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && (candidate.textContent ?? '').trim().length > 0;
        });

        return {
            title: (widget.querySelector('.quick-input-title')?.textContent ?? '').trim(),
            placeholder: input?.placeholder ?? '',
            hasInput: !!input,
            rowCount: visibleRows.length
        };
    });
}

function isDeployInputBox(state: QuickInputState): boolean {
    return /Enter hosted agent name|container registry/i.test(`${state.title} ${state.placeholder}`);
}

async function waitForDeployPromptReady(mainWindow: Page, timeoutMs = 15_000): Promise<QuickInputState> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        const state = await visibleQuickInputState(mainWindow);
        if (state.rowCount > 0 || (state.hasInput && isDeployInputBox(state))) {
            return state;
        }
        await sleep(200);
    }

    const snapshot = await workbenchSnapshot(mainWindow);
    throw new Error(`Deploy prompt did not become ready: ${JSON.stringify(snapshot)}`);
}

function getErrorMessage(err: unknown): string {
    if (err instanceof Error) {
        return err.stack ?? err.message;
    }
    return String(err);
}

async function logDeployDiagnostics(mainWindow: Page, agentName: string, err: unknown): Promise<void> {
    try {
        const snapshot = await workbenchSnapshot(mainWindow);
        const { outputText, panelText, ...summary } = snapshot;
        // eslint-disable-next-line no-console
        console.error(`[deploy spec] Deployment failed for ${agentName}: ${getErrorMessage(err)}`);
        // eslint-disable-next-line no-console
        console.error(`[deploy spec] Workbench snapshot: ${JSON.stringify(summary)}`);

        if (outputText) {
            // eslint-disable-next-line no-console
            console.error(`[deploy spec] Visible Output text:\n${outputText}`);
        }
        if (panelText && panelText !== outputText) {
            // eslint-disable-next-line no-console
            console.error(`[deploy spec] Visible panel text:\n${panelText}`);
        }
    } catch (diagnosticError) {
        // eslint-disable-next-line no-console
        console.error(`[deploy spec] Failed to collect deploy diagnostics: ${getErrorMessage(diagnosticError)}`);
    }
}

function findDeployFailureText(snapshot: Awaited<ReturnType<typeof workbenchSnapshot>>): string | undefined {
    const findFailureLine = (text: string): string | undefined =>
        text
            .replace(/\r/g, '')
            .split('\n')
            .map((line) =>
                line
                    .replace(/Source: Microsoft Foundry/g, '')
                    .replace(/Report an issue/g, '')
                    .replace(/\s+/g, ' ')
                    .trim()
            )
            .filter(Boolean)
            .find((line) =>
                /deployment failed|failed to (get|create|build|push|deploy|assign|start)|\berror:/i.test(line)
            );

    return findFailureLine(snapshot.outputText) ?? findFailureLine(snapshot.notifications.join('\n'));
}

async function getDeployFailureText(mainWindow: Page): Promise<string | undefined> {
    const initialSnapshot = await workbenchSnapshot(mainWindow);
    const initialFailureText = findDeployFailureText(initialSnapshot);
    if (!initialFailureText) {
        return undefined;
    }

    await sleep(1_500);
    const refreshedSnapshot = await workbenchSnapshot(mainWindow);
    return findDeployFailureText(refreshedSnapshot) ?? initialFailureText;
}

function formatFrameTimeout(mainWindow: Page, timeoutMs: number): string {
    const frameUrls = mainWindow.frames().map((frame) => frame.url());
    return (
        `No playground webview frame found after ${timeoutMs}ms. ` +
        `${frameUrls.length} frame(s): ${frameUrls.join(' | ')}`
    );
}

async function waitForPlaygroundOrDeployFailure(mainWindow: Page, timeoutMs: number): Promise<Frame> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        try {
            return await findPlaygroundFrame(mainWindow, 1_000);
        } catch {
            // Keep polling so deploy failures surface before the long playground timeout.
        }

        const failureText = await getDeployFailureText(mainWindow);
        if (failureText) {
            throw new Error(`Deploy failed before playground opened: ${failureText}`);
        }
    }

    throw new Error(formatFrameTimeout(mainWindow, timeoutMs));
}

/**
 * Drive the Deploy Hosted Agent command
 * (`azure-ai-foundry.commandPalette.deployWorkflow`). The Quick Pick chain
 * is dynamic (capability host confirmation may or may not appear, registry
 * selection may or may not appear, etc.), so we accept defaults until the
 * deployment progress notification starts and the playground auto-opens.
 */
async function deployAndWaitForPlayground(mainWindow: Page, agentName: string): Promise<void> {
    await runCommand(mainWindow, DEPLOY_COMMAND_TITLE);

    let acceptedPromptCount = 0;
    for (let i = 0; i < 8; i++) {
        try {
            await waitForQuickPick(mainWindow, 8_000);
        } catch {
            break;
        }
        const promptState = await waitForDeployPromptReady(mainWindow);
        await sleep(400);
        await quickPickAccept(mainWindow);
        acceptedPromptCount++;
        await sleep(800);
    }

    if (acceptedPromptCount === 0 && !(await playgroundIsOpen(mainWindow))) {
        const snapshot = await workbenchSnapshot(mainWindow);
        throw new Error(`Deploy command did not show prompts or open the playground: ${JSON.stringify(snapshot)}`);
    }

    const snapshotAfterPrompts = await workbenchSnapshot(mainWindow);
    if (snapshotAfterPrompts.quickPick.placeholder === 'Type the name of a command to run.') {
        throw new Error(`Deploy command palette did not close: ${JSON.stringify(snapshotAfterPrompts)}`);
    }

    // Container build + ACR push + agent create can take many minutes —
    // allow a generous wait. The extension auto-opens the playground for
    // the deployed agent on success.
    const frame = await waitForPlaygroundOrDeployFailure(mainWindow, 20 * 60_000);

    // Sanity check: the playground's workflows-select should reflect the
    // deployed agent within a few seconds.
    try {
        await waitForPredicate(
            async () => (await getWorkflowsSelectValue(frame)) === agentName,
            `playground workflows-select to show ${agentName}`,
            45_000
        );
    } catch (err) {
        const observed = await getWorkflowsSelectValue(frame);
        // eslint-disable-next-line no-console
        console.error(
            `[deploy spec] workflows-select mismatch. Expected="${agentName}" observed="${observed ?? '<null>'}".`
        );
        throw err;
    }
}

const samples = discoverSamples();
if (samples.length === 0) {
    // eslint-disable-next-line no-console
    console.warn(
        '[deploy spec] discoverSamples() returned 0 entries. ' +
            'Check FOUNDRY_SAMPLES_INCLUDE / FOUNDRY_SAMPLES_EXCLUDE if filtering, ' +
            'or verify samples/<lang>/hosted-agents/ contains agent.yaml + Dockerfile pairs.'
    );
}

for (let i = 0; i < samples.length; i++) {
    const sample = samples[i];
    // Embed [python] / [csharp] tags in the title so playwright.config.ts can
    // grep them into per-language projects.
    test.describe.serial(`deploy [${sample.language}] ${sample.displayName}`, () => {
        let launched: LaunchedVSCode | undefined;
        let workspaceFolder: string | undefined;
        let agentName: string;
        let attached: { browser: import('@playwright/test').Browser } | undefined;

        test.beforeEach(async () => {
            agentName = deterministicAgentName(sample, i);
            recordDeployedAgent(agentName);
            workspaceFolder = createSampleWorkspace(sample.absolutePath, agentName);
            rewriteAgentName(workspaceFolder, agentName);

            launched = await launchVSCode({
                workspaceFolder,
                cdpPort: DEFAULT_DEPLOY_CDP_PORT,
                profileName: `foundry-samples-${agentName}`
            });
        });

        test.afterEach(async () => {
            if (attached) {
                try {
                    await attached.browser.close();
                } catch {
                    // best-effort
                }
                attached = undefined;
            }
            if (launched) {
                try {
                    await launched.quit();
                } catch {
                    // best-effort
                }
                launched = undefined;
            }
            if (workspaceFolder) {
                removeSampleWorkspace(workspaceFolder);
                workspaceFolder = undefined;
            }
        });

        test(`deploys without prompts beyond defaults [${sample.language}]`, async () => {
            if (!launched || !workspaceFolder) {
                throw new Error('beforeEach did not initialize launcher / workspace');
            }
            const { mainWindow, browser } = await attachToVSCode(launched.cdpEndpoint);
            attached = { browser };

            // Sanity-check the workspace was set up the way we expect.
            expect(fs.existsSync(path.join(workspaceFolder, 'agent.yaml'))).toBe(true);
            expect(fs.existsSync(path.join(workspaceFolder, 'Dockerfile'))).toBe(true);
            const protocols = readHostedAgentProtocols(workspaceFolder);

            // Wait briefly for the AI Foundry extension to activate before
            // running its commands.
            await mainWindow.waitForTimeout(2_000);

            // Close any editors that VS Code auto-opened (welcome, etc.).
            await closeAllEditors(mainWindow).catch(() => undefined);

            try {
                await deployAndWaitForPlayground(mainWindow, agentName);
                await smokeTestDeployedAgentApis(agentName, protocols, { sampleRelativePath: sample.relativePath });
            } catch (err) {
                await logDeployDiagnostics(mainWindow, agentName, err);
                throw err;
            }
        });
    });
}
