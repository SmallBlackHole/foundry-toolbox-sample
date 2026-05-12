/**
 * Discover deployable hosted-agent samples under
 * samples/<lang>/hosted-agents/. A sample is "deployable" when its directory
 * contains both an `agent.yaml` (for metadata) and a `Dockerfile` (so the
 * build context can be packaged).
 *
 * Filtering:
 *   - FOUNDRY_SAMPLES_INCLUDE  optional regex; only samples whose relative
 *                              path matches are kept.
 *   - FOUNDRY_SAMPLES_EXCLUDE  optional regex; samples whose relative path
 *                              matches are dropped.
 *
 * Discovery is synchronous and runs at spec-load time so Playwright can
 * generate a stable list of test cases.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';

export type SampleLanguage = 'python' | 'csharp';

export interface SampleDescriptor {
    language: SampleLanguage;
    /** Relative path from the repo root, e.g. "samples/python/hosted-agents/.../hello-world". */
    relativePath: string;
    /** Absolute path to the sample directory (containing agent.yaml + Dockerfile). */
    absolutePath: string;
    /** Stable, human-readable name suitable for the Playwright test title. */
    displayName: string;
}

const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

const ROOTS: { language: SampleLanguage; root: string }[] = [
    { language: 'python', root: path.join(REPO_ROOT, 'samples', 'python', 'hosted-agents') },
    { language: 'csharp', root: path.join(REPO_ROOT, 'samples', 'csharp', 'hosted-agents') }
];

function walk(dir: string, out: string[]): void {
    if (!fs.existsSync(dir)) {
        return;
    }
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    // Stop walking deeper if this directory itself is a sample (has both files).
    const hasAgentYaml = entries.some((e) => e.isFile() && e.name === 'agent.yaml');
    const hasDockerfile = entries.some((e) => e.isFile() && e.name === 'Dockerfile');
    if (hasAgentYaml && hasDockerfile) {
        out.push(dir);
        return;
    }
    for (const entry of entries) {
        if (!entry.isDirectory()) {
            continue;
        }
        if (entry.name.startsWith('.') || entry.name === 'node_modules') {
            continue;
        }
        walk(path.join(dir, entry.name), out);
    }
}

function buildDisplayName(language: SampleLanguage, relativePath: string): string {
    // Strip the leading "samples/<lang>/hosted-agents/" prefix so the name is short.
    const prefix = `samples/${language}/hosted-agents/`.replace(/\\/g, '/');
    const normalized = relativePath.replace(/\\/g, '/');
    const tail = normalized.startsWith(prefix) ? normalized.slice(prefix.length) : normalized;
    return tail || normalized;
}

function compileFilter(envName: string): RegExp | undefined {
    const raw = process.env[envName];
    if (!raw) {
        return undefined;
    }
    try {
        return new RegExp(raw);
    } catch (err) {
        throw new Error(`${envName} is not a valid regex: ${raw} (${(err as Error).message})`);
    }
}

export function discoverSamples(): SampleDescriptor[] {
    const include = compileFilter('FOUNDRY_SAMPLES_INCLUDE');
    const exclude = compileFilter('FOUNDRY_SAMPLES_EXCLUDE');

    const out: SampleDescriptor[] = [];
    for (const { language, root } of ROOTS) {
        const matches: string[] = [];
        walk(root, matches);
        for (const abs of matches) {
            const rel = path.relative(REPO_ROOT, abs).replace(/\\/g, '/');
            if (include && !include.test(rel)) {
                continue;
            }
            if (exclude && exclude.test(rel)) {
                continue;
            }
            out.push({
                language,
                relativePath: rel,
                absolutePath: abs,
                displayName: buildDisplayName(language, rel)
            });
        }
    }
    out.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
    return out;
}
