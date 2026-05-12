/**
 * Launches VS Code (stable) with the AI Foundry extension, with Chrome
 * DevTools Protocol enabled so Playwright can connect via
 * `chromium.connectOverCDP`.
 *
 * Two extension install modes (checked in order):
 *
 *   1. Development build — set `AI_FOUNDRY_EXTENSION_PATH` to the root of
 *      a built ai-foundry-for-vscode working tree (must contain
 *      `dist/extension.js`). Loaded via `--extensionDevelopmentPath`.
 *   2. Marketplace (default) — installs `TeamsDevApp.vscode-ai-foundry`
 *      from the VS Code marketplace. Pin a version with
 *      `AI_FOUNDRY_EXTENSION_VERSION`.
 *
 * The test environment suppresses telemetry, and `AI_FOUNDRY_HEADLESS_AUTH`
 * makes auth and project selection use TestAuthenticationService /
 * TestDefaultProjectService inside the AI Foundry extension.
 */

import * as path from 'node:path';
import * as fs from 'node:fs';
import { spawn, spawnSync, ChildProcess } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { chromium } from '@playwright/test';
import { downloadAndUnzipVSCode, resolveCliArgsFromVSCodeExecutablePath } from '@vscode/test-electron';
import { fixture, fixtureEnvVars } from './target';

export const DEFAULT_CDP_PORT = Number(process.env.AI_FOUNDRY_PLAYWRIGHT_CDP_PORT ?? 9233);

const AI_FOUNDRY_EXTENSION_ID = 'TeamsDevApp.vscode-ai-foundry';

// ---------------------------------------------------------------------------
// Profile / settings
// ---------------------------------------------------------------------------

function profileDir(profileName = 'foundry-samples-e2e'): string {
    return path.join(__dirname, '..', '.vscode-test', profileName);
}

/** Shared extensions directory so the VSIX is installed only once. */
const SHARED_EXTENSIONS_DIR = path.join(__dirname, '..', '.vscode-test', 'shared-extensions');

function ensureDirs(profileName?: string): { userDataDir: string; extensionsDir: string } {
    const dir = profileDir(profileName);
    const userDataDir = path.join(dir, 'user-data');
    const extensionsDir = SHARED_EXTENSIONS_DIR;
    fs.mkdirSync(userDataDir, { recursive: true });
    fs.mkdirSync(extensionsDir, { recursive: true });
    writeDefaultSettings(userDataDir);
    return { userDataDir, extensionsDir };
}

function writeDefaultSettings(userDataDir: string): void {
    const settingsDir = path.join(userDataDir, 'User');
    fs.mkdirSync(settingsDir, { recursive: true });
    const settingsPath = path.join(settingsDir, 'settings.json');

    const requiredSettings: Record<string, unknown> = {
        'chat.commandCenter.enabled': false,
        'chat.editor.enabled': false,
        'chat.sidebar.enabled': false,
        'chat.agent.enabled': false,
        'workbench.panel.chat.view.copilot.focused': false,
        'settingsSync.keybindingsPerPlatform': false,
        'workbench.startupEditor': 'none',
        'workbench.tips.enabled': false,
        'extensions.ignoreRecommendations': true,
        'telemetry.telemetryLevel': 'off',
        'window.commandCenter': false,
        'window.dialogStyle': 'custom'
    };

    let existing: Record<string, unknown> = {};
    try {
        if (fs.existsSync(settingsPath)) {
            existing = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
        }
    } catch {
        // Corrupt or empty file — overwrite.
    }
    const merged = { ...existing, ...requiredSettings };
    fs.writeFileSync(settingsPath, JSON.stringify(merged, null, 4) + '\n');
}

// ---------------------------------------------------------------------------
// Extension installation
// ---------------------------------------------------------------------------

function installExtension(vscodeExe: string, extensionsDir: string, extSpec: string): void {
    const [cli, ...cliArgs] = resolveCliArgsFromVSCodeExecutablePath(vscodeExe, { reuseMachineInstall: true });
    // eslint-disable-next-line no-console
    console.log(`[launcher] Installing extension: ${extSpec}`);
    const result = spawnSync(
        cli,
        [...cliArgs, '--install-extension', extSpec, '--extensions-dir', extensionsDir, '--force'],
        {
            encoding: 'utf-8',
            stdio: ['pipe', 'pipe', 'pipe'],
            input: 'y\n',
            env: { ...process.env, DONT_PROMPT_WSL_INSTALL: '1' },
            maxBuffer: 10 * 1024 * 1024,
            shell: process.platform === 'win32'
        }
    );
    if (result.stdout) {
        // eslint-disable-next-line no-console
        console.log(result.stdout.trimEnd());
    }
    if (result.stderr) {
        // eslint-disable-next-line no-console
        console.error(result.stderr.trimEnd());
    }
    if (result.status !== 0) {
        const details = [`exit code ${result.status}`];
        if (result.signal) {
            details.push(`signal ${result.signal}`);
        }
        if (result.error) {
            details.push(result.error.message);
        }
        throw new Error(`Failed to install extension ${extSpec} (${details.join(', ')})`);
    }
}

function installMarketplaceExtension(vscodeExe: string, extensionsDir: string): void {
    const f = fixture();
    if (f.extensionPath) {
        // Development mode — loaded via --extensionDevelopmentPath at launch.
        return;
    }

    // Install from VS Code marketplace with --force so a reused shared extensions
    // directory does not keep an older marketplace version between test runs.
    const version = process.env.AI_FOUNDRY_EXTENSION_VERSION;
    const extSpec = version ? `${AI_FOUNDRY_EXTENSION_ID}@${version}` : AI_FOUNDRY_EXTENSION_ID;
    // eslint-disable-next-line no-console
    console.log(`[launcher] Installing/updating from marketplace: ${extSpec}`);
    installExtension(vscodeExe, extensionsDir, extSpec);
    logInstalledExtensionVersion(extensionsDir, AI_FOUNDRY_EXTENSION_ID);
}

// ---------------------------------------------------------------------------
// Post-install cleanup: remove transitive deps that cause sign-in prompts
// ---------------------------------------------------------------------------

function findExtensionFolder(extensionsDir: string, extensionId: string): string | undefined {
    const lower = extensionId.toLowerCase();
    const prefixDot = lower + '-';
    const prefixDash = lower.replace(/\./g, '-') + '-';
    let entries: string[];
    try {
        entries = fs.readdirSync(extensionsDir);
    } catch {
        return undefined;
    }
    return entries.find((entry) => {
        const lowerEntry = entry.toLowerCase();
        return lowerEntry.startsWith(prefixDot) || lowerEntry.startsWith(prefixDash);
    });
}

function logInstalledExtensionVersion(extensionsDir: string, extensionId: string): void {
    const extensionFolder = findExtensionFolder(extensionsDir, extensionId);
    if (!extensionFolder) {
        // eslint-disable-next-line no-console
        console.warn(`[launcher] Extension ${extensionId} was not found after install.`);
        return;
    }

    try {
        const packageJsonPath = path.join(extensionsDir, extensionFolder, 'package.json');
        const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8')) as { version?: string };
        // eslint-disable-next-line no-console
        console.log(`[launcher] Extension ready: ${extensionId} v${packageJson.version ?? 'unknown'}`);
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        // eslint-disable-next-line no-console
        console.warn(`[launcher] Could not read installed extension version for ${extensionId}: ${message}`);
    }
}

interface PrivateDBus {
    address: string;
    pid: number;
}

function shouldUsePrivateDBus(): boolean {
    if (process.platform !== 'linux') {
        return false;
    }
    if (process.env.AI_FOUNDRY_PLAYWRIGHT_NO_PRIVATE_DBUS === '1') {
        return false;
    }
    return process.env.CI === 'true' || process.env.AI_FOUNDRY_PLAYWRIGHT_PRIVATE_DBUS === '1';
}

function spawnPrivateDBus(): PrivateDBus | undefined {
    if (!shouldUsePrivateDBus()) {
        return undefined;
    }

    try {
        const result = spawnSync('dbus-daemon', ['--session', '--fork', '--print-address=1', '--print-pid=1'], {
            encoding: 'utf-8'
        });
        if (result.status !== 0) {
            // eslint-disable-next-line no-console
            console.warn(`[launcher] dbus-daemon spawn failed (status ${result.status}): ${result.stderr}`);
            return undefined;
        }

        const lines = result.stdout
            .split('\n')
            .map((s) => s.trim())
            .filter(Boolean);
        const address = lines[0];
        const pid = Number(lines[1]);
        if (!address || !Number.isFinite(pid)) {
            // eslint-disable-next-line no-console
            console.warn(`[launcher] Failed to parse dbus-daemon output: ${result.stdout}`);
            return undefined;
        }

        // eslint-disable-next-line no-console
        console.log(`[launcher] Spawned private D-Bus session (pid ${pid}) for VS Code.`);
        return { address, pid };
    } catch (err) {
        // eslint-disable-next-line no-console
        console.warn(`[launcher] Could not spawn private dbus-daemon: ${(err as Error).message}`);
        return undefined;
    }
}

function stopPrivateDBus(privateDBus: PrivateDBus | undefined): void {
    if (!privateDBus) {
        return;
    }
    try {
        process.kill(privateDBus.pid, 'SIGTERM');
    } catch {
        // Already exited.
    }
}

// ---------------------------------------------------------------------------
// CDP wait
// ---------------------------------------------------------------------------

async function waitForCDP(port: number, timeoutMs = 60_000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        try {
            const resp = await fetch(`http://127.0.0.1:${port}/json/version`);
            if (resp.ok) {
                return;
            }
        } catch {
            // not ready yet
        }
        await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error(`CDP endpoint at port ${port} not available after ${timeoutMs}ms`);
}

async function waitForProcessExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
    if (child.exitCode !== null || child.signalCode !== null) {
        return true;
    }

    return new Promise<boolean>((resolve) => {
        const timeout = setTimeout(() => {
            child.off('exit', onExit);
            resolve(false);
        }, timeoutMs);
        const onExit = (): void => {
            clearTimeout(timeout);
            resolve(true);
        };
        child.once('exit', onExit);
    });
}

function hasProcessExited(child: ChildProcess): boolean {
    return child.exitCode !== null || child.signalCode !== null;
}

async function closeWithBrowserCommand(cdpEndpoint: string): Promise<void> {
    const browser = await chromium.connectOverCDP(cdpEndpoint);
    try {
        await browser.close();
    } catch (err) {
        if (!String((err as Error).message).includes('Target page, context or browser has been closed')) {
            throw err;
        }
    }
}

async function closeWithQuitShortcut(cdpEndpoint: string): Promise<void> {
    const browser = await chromium.connectOverCDP(cdpEndpoint);
    try {
        const page = browser.contexts().flatMap((context) => context.pages())[0];
        if (!page) {
            return;
        }
        await page.bringToFront();
        await page.keyboard.press(process.platform === 'darwin' ? 'Meta+Q' : 'Control+Q');
    } finally {
        await browser.close().catch(() => undefined);
    }
}

async function requestGracefulQuit(cdpEndpoint: string, child: ChildProcess): Promise<string | undefined> {
    try {
        await closeWithQuitShortcut(cdpEndpoint);
        if (await waitForProcessExit(child, 10_000)) {
            return 'Ctrl+Q';
        }
    } catch (err) {
        // eslint-disable-next-line no-console
        console.warn(`[launcher] Ctrl+Q quit failed: ${(err as Error).message}`);
    }

    try {
        await closeWithBrowserCommand(cdpEndpoint);
        if (await waitForProcessExit(child, 5_000)) {
            return 'CDP Browser.close';
        }
    } catch (err) {
        // eslint-disable-next-line no-console
        console.warn(`[launcher] CDP Browser.close failed: ${(err as Error).message}`);
    }

    return undefined;
}

// ---------------------------------------------------------------------------
// Launch
// ---------------------------------------------------------------------------

export interface LaunchedVSCode {
    process: ChildProcess;
    cdpPort: number;
    cdpEndpoint: string;
    quit: () => Promise<void>;
}

export async function launchVSCode(
    options: { workspaceFolder?: string; cdpPort?: number; profileName?: string } = {}
): Promise<LaunchedVSCode> {
    const f = fixture();
    const extensionPath = f.extensionPath;
    if (extensionPath) {
        const distEntry = path.join(extensionPath, 'dist', 'extension.js');
        if (!fs.existsSync(distEntry)) {
            throw new Error(
                `AI Foundry extension is not built at ${extensionPath}. ` +
                    'Run `npm run build:playwright` from that repo first, ' +
                    'or unset AI_FOUNDRY_EXTENSION_PATH to use the marketplace extension.'
            );
        }
    }

    const { userDataDir, extensionsDir } = ensureDirs(options.profileName);

    const vscodeVersion = process.env.AI_FOUNDRY_PLAYWRIGHT_VSCODE_VERSION || 'stable';
    // eslint-disable-next-line no-console
    console.log(`[launcher] Downloading/locating VS Code ${vscodeVersion}...`);
    const vscodeExe = await downloadAndUnzipVSCode(vscodeVersion);
    installMarketplaceExtension(vscodeExe, extensionsDir);

    const cdpPort = options.cdpPort ?? DEFAULT_CDP_PORT;
    const args = [
        `--user-data-dir=${userDataDir}`,
        `--extensions-dir=${extensionsDir}`,
        `--remote-debugging-port=${cdpPort}`,
        '--password-store=basic',
        '--disable-gpu',
        '--disable-workspace-trust'
    ];
    if (extensionPath) {
        args.unshift(`--extensionDevelopmentPath=${extensionPath}`);
    }
    const folder = options.workspaceFolder ?? process.env.AI_FOUNDRY_PLAYWRIGHT_WORKSPACE;
    if (folder) {
        args.push(`--folder-uri=${pathToFileURL(folder).href}`);
    }
    if (process.platform !== 'win32') {
        args.push('--no-sandbox');
    }

    const modeLabel = extensionPath
        ? `dev: ${extensionPath}`
        : `marketplace: ${AI_FOUNDRY_EXTENSION_ID}`;

    // eslint-disable-next-line no-console
    console.log(`[launcher] Spawning VS Code (CDP port ${cdpPort}, ${modeLabel})...`);
    const privateDBus = spawnPrivateDBus();
    const child = spawn(vscodeExe, args, {
        stdio: ['ignore', 'inherit', 'inherit'],
        env: {
            ...process.env,
            ...fixtureEnvVars(),
            DONT_PROMPT_WSL_INSTALL: '1',
            ...(privateDBus ? { DBUS_SESSION_BUS_ADDRESS: privateDBus.address } : {})
        },
        detached: false
    });

    try {
        await waitForCDP(cdpPort);
    } catch (err) {
        if (!hasProcessExited(child)) {
            child.kill('SIGTERM');
        }
        stopPrivateDBus(privateDBus);
        throw err;
    }
    // eslint-disable-next-line no-console
    console.log(`[launcher] CDP ready at http://127.0.0.1:${cdpPort}`);

    return {
        process: child,
        cdpPort,
        cdpEndpoint: `http://127.0.0.1:${cdpPort}`,
        quit: async () => {
            try {
                const cdpEndpoint = `http://127.0.0.1:${cdpPort}`;
                const quitMethod = await requestGracefulQuit(cdpEndpoint, child);
                if (quitMethod) {
                    // eslint-disable-next-line no-console
                    console.log(`[launcher] VS Code exited via ${quitMethod}.`);
                }
                if (!quitMethod && !hasProcessExited(child)) {
                    // eslint-disable-next-line no-console
                    console.warn('[launcher] Graceful quit failed; sending SIGTERM.');
                    child.kill('SIGTERM');
                }
                if (!(await waitForProcessExit(child, 8_000)) && !hasProcessExited(child)) {
                    // eslint-disable-next-line no-console
                    console.warn('[launcher] VS Code did not exit after SIGTERM; sending SIGKILL.');
                    child.kill('SIGKILL');
                    await waitForProcessExit(child, 2_000);
                }
            } finally {
                stopPrivateDBus(privateDBus);
            }
        }
    };
}
