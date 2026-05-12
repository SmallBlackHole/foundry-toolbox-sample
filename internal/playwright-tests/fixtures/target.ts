/**
 * Fixture target for the foundry-samples Playwright suite.
 *
 * Required: AI_FOUNDRY_PROJECT_URI (ARM resource path of the Foundry project;
 * a leading "/resource" segment is tolerated).
 *
 * Optional: AI_FOUNDRY_EXTENSION_PATH (absolute path to a built
 * ai-foundry-for-vscode working tree containing dist/extension.js). When
 * unset, the launcher installs the published extension from the VS Code
 * marketplace (TeamsDevApp.vscode-ai-foundry). Pin a specific marketplace
 * version with AI_FOUNDRY_EXTENSION_VERSION.
 *
 * Subscription / resource group / account / project / location are derived
 * from the project URI. Location is resolved at fixture setup time via an
 * ARM lookup against the Cognitive Services account that owns the project.
 *
 * The harness enables the AI Foundry extension's headless auth mode and
 * mirrors the per-field env vars used by TestDefaultProjectService so that
 * the spawned VS Code process picks up the project context with no
 * interactive sign-in.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';

export interface FixtureTarget {
    subscriptionId: string;
    resourceGroup: string;
    accountName: string;
    projectName: string;
    projectArmId: string;
    location: string;
    /**
     * Absolute path to a built ai-foundry-for-vscode working tree, when the
     * developer wants to test against local changes. Undefined means the
     * launcher installs the marketplace extension instead.
     */
    extensionPath?: string;
}

export interface ParsedProjectUri {
    subscriptionId: string;
    resourceGroup: string;
    accountName: string;
    projectName: string;
    projectArmId: string;
}

const PROJECT_URI_PATTERN =
    /^\/subscriptions\/([^/]+)\/resourceGroups\/([^/]+)\/providers\/Microsoft\.CognitiveServices\/accounts\/([^/]+)\/projects\/([^/]+)$/i;

export function parseProjectUri(uri: string): ParsedProjectUri {
    let trimmed = uri.trim().replace(/\/+$/, '');
    if (trimmed.toLowerCase().startsWith('/resource/')) {
        trimmed = trimmed.slice('/resource'.length);
    }
    const m = PROJECT_URI_PATTERN.exec(trimmed);
    if (!m) {
        throw new Error(
            'AI_FOUNDRY_PROJECT_URI is not a valid Foundry project resource path. ' +
                'Expected: /subscriptions/<sub>/resourceGroups/<rg>/providers/' +
                'Microsoft.CognitiveServices/accounts/<account>/projects/<project>. ' +
                `Got: ${uri}`
        );
    }
    return {
        subscriptionId: m[1],
        resourceGroup: m[2],
        accountName: m[3],
        projectName: m[4],
        projectArmId: trimmed
    };
}

let _fixture: FixtureTarget | undefined;

const FIXTURE_FILE = path.join(__dirname, '..', '.vscode-test', 'fixture.json');

export function initFixture(target: FixtureTarget): void {
    _fixture = target;
    fs.mkdirSync(path.dirname(FIXTURE_FILE), { recursive: true });
    fs.writeFileSync(FIXTURE_FILE, JSON.stringify(target, null, 2));
}

export function fixture(): FixtureTarget {
    if (!_fixture && fs.existsSync(FIXTURE_FILE)) {
        _fixture = JSON.parse(fs.readFileSync(FIXTURE_FILE, 'utf-8')) as FixtureTarget;
    }
    if (!_fixture) {
        throw new Error('Fixture not initialised. ensureFixtureConfigured() must run before tests.');
    }
    return _fixture;
}

/**
 * Build the env vars that the spawned VS Code process needs for the
 * test environment. Decomposes the project URI back into the per-field vars
 * that TestDefaultProjectService expects in the AI Foundry extension.
 */
export function fixtureEnvVars(): Record<string, string> {
    const f = fixture();
    return {
        AI_FOUNDRY_ENVIRONMENT: 'test',
        AI_FOUNDRY_HEADLESS_AUTH: 'true',
        AI_FOUNDRY_PROJECT_ID: f.projectArmId,
        AI_FOUNDRY_PROJECT_NAME: f.projectName,
        AI_FOUNDRY_SUBSCRIPTION_ID: f.subscriptionId,
        AI_FOUNDRY_RESOURCE_GROUP: f.resourceGroup,
        AI_FOUNDRY_LOCATION: f.location,
        AI_FOUNDRY_ACCOUNT_NAME: f.accountName,
        ...(process.env.AI_FOUNDRY_TENANT_ID ? { AI_FOUNDRY_TENANT_ID: process.env.AI_FOUNDRY_TENANT_ID } : {})
    };
}

/**
 * Connection (data-plane) endpoint used by the teardown HTTP client to
 * delete deployed agents.
 */
export function projectConnection(target: FixtureTarget = fixture()): string {
    return `https://${target.accountName}.services.ai.azure.com/api/projects/${target.projectName}`;
}
