/**
 * Best-effort cleanup of agents created by the foundry-samples deploy spec.
 *
 * Reads the file-backed tracker (helpers/sessionTracker.ts) and DELETEs
 * each tracked agent (which removes all of its versions). Self-contained:
 * uses `@azure/identity`'s DefaultAzureCredential and the built-in fetch.
 *
 * All errors are logged and swallowed so teardown never fails the run.
 */

import { DefaultAzureCredential } from '@azure/identity';
import { fixture, projectConnection, type FixtureTarget } from './target';
import { readDeployedAgents } from '../helpers/sessionTracker';

const FOUNDRY_API_VERSION = '2025-11-15-preview';
const DATA_PLANE_SCOPE = 'https://ai.azure.com/.default';

async function getDataPlaneToken(): Promise<string> {
    const credential = new DefaultAzureCredential(
        process.env.AI_FOUNDRY_TENANT_ID ? { tenantId: process.env.AI_FOUNDRY_TENANT_ID } : undefined
    );
    const token = await credential.getToken(DATA_PLANE_SCOPE);
    if (!token) {
        throw new Error(`Could not acquire token for ${DATA_PLANE_SCOPE}.`);
    }
    return token.token;
}

async function deleteAgent(connection: string, agentName: string, bearer: string): Promise<void> {
    const url = `${connection}/agents/${encodeURIComponent(agentName)}?api-version=${FOUNDRY_API_VERSION}`;
    const resp = await fetch(url, {
        method: 'DELETE',
        headers: { Authorization: `Bearer ${bearer}` }
    });
    if (!resp.ok && resp.status !== 404) {
        throw new Error(`deleteAgent(${agentName}) -> ${resp.status} ${resp.statusText}`);
    }
}

export async function cleanupTrackedArtefacts(): Promise<void> {
    let target: FixtureTarget;
    try {
        target = fixture();
    } catch {
        // Fixture never initialised — nothing to clean.
        return;
    }
    const connection = projectConnection(target);

    let bearer: string;
    try {
        bearer = await getDataPlaneToken();
    } catch (err) {
        // eslint-disable-next-line no-console
        console.warn('[teardown] Skipping agent cleanup — could not get token:', (err as Error).message);
        return;
    }

    const agents = readDeployedAgents();
    for (const a of agents) {
        try {
            await deleteAgent(connection, a.agentName, bearer);
            // eslint-disable-next-line no-console
            console.log(`[teardown] Deleted agent ${a.agentName}`);
        } catch (err) {
            // eslint-disable-next-line no-console
            console.warn(`[teardown] ${(err as Error).message}`);
        }
    }
}
