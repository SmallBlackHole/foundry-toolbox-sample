/**
 * Per-test workspace folders for the foundry-samples deploy spec.
 *
 * The deploy flow (`hostedAgentDeploySelectionService.ts`) reads the agent
 * root from `workspace.workspaceFolders?.at(0)` — i.e. the workspace root
 * IS the agent root. To match real-user usage and avoid mutating the source
 * tree, each test:
 *
 *   1. Copies the sample's directory into a per-test temp folder.
 *   2. Rewrites `name:` in agent.yaml so the deployed agent has a unique
 *      `pw-` prefixed name. This avoids collisions with prior runs and
 *      with the canonical sample names.
 *
 * The folder is removed in afterEach.
 */

import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

/**
 * Recursively copy a source directory into `destination`. Skips
 * common cache folders (.venv, __pycache__, bin, obj, node_modules) so
 * tests don't pull in gigabytes of artefacts that aren't needed for the
 * Docker build context.
 */
function copyDirectory(source: string, destination: string): void {
    const SKIP = new Set(['.venv', '__pycache__', 'bin', 'obj', 'node_modules', '.git', '.vs', '.idea']);
    fs.mkdirSync(destination, { recursive: true });
    for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
        if (SKIP.has(entry.name)) {
            continue;
        }
        const src = path.join(source, entry.name);
        const dst = path.join(destination, entry.name);
        if (entry.isDirectory()) {
            copyDirectory(src, dst);
        } else if (entry.isSymbolicLink()) {
            // Skip symlinks — they rarely make sense outside the original tree.
            continue;
        } else {
            fs.copyFileSync(src, dst);
        }
    }
}

/**
 * Create a per-test workspace by copying `sampleSourceDir` into a fresh temp
 * folder. The destination folder is named after the requested agent name so
 * the workspace basename is meaningful in any error messages.
 */
export function createSampleWorkspace(sampleSourceDir: string, agentName: string): string {
    const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'pw-foundry-samples-'));
    const dest = path.join(parent, agentName);
    copyDirectory(sampleSourceDir, dest);
    return dest;
}

/** Best-effort recursive removal of a per-test workspace folder (and its parent). */
export function removeSampleWorkspace(folder: string): void {
    try {
        const parent = path.dirname(folder);
        fs.rmSync(parent, { recursive: true, force: true });
    } catch {
        // ignore
    }
}

/**
 * Rewrite the `name:` field in agent.yaml to `agentName`. Preserves the rest
 * of the file (including comments and key order) by doing a regex replace
 * rather than a YAML round-trip. Throws if no `name:` line is found.
 */
export function rewriteAgentName(workspaceFolder: string, agentName: string): void {
    const yamlPath = path.join(workspaceFolder, 'agent.yaml');
    const original = fs.readFileSync(yamlPath, 'utf-8');
    // Match a top-level `name: ...` (no leading whitespace). agent.yaml in
    // the samples uses unquoted, single-line names so a simple replace is
    // safe; we don't try to handle block scalars / multiline names.
    const replaced = original.replace(/^name:\s*.+$/m, `name: ${agentName}`);
    if (replaced === original) {
        throw new Error(`agent.yaml at ${yamlPath} did not contain a top-level "name:" line.`);
    }
    fs.writeFileSync(yamlPath, replaced);
}
