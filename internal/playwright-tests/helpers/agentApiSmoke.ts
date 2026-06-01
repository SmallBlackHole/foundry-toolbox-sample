/**
 * Direct data-plane smoke tests for hosted-agent endpoints created by the
 * deploy Playwright suite. These calls validate the deployed endpoint itself,
 * beyond the VS Code playground opening successfully.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomUUID } from 'node:crypto';
import { DefaultAzureCredential } from '@azure/identity';
import { fixture, projectConnection } from '../fixtures/target';

export type HostedAgentProtocol = 'invocations' | 'responses';

const FOUNDRY_API_VERSION = '2025-11-15-preview';
const DATA_PLANE_SCOPE = 'https://ai.azure.com/.default';
const HOSTED_AGENTS_FEATURE_FLAG_HEADER = 'HostedAgents=V1Preview';
const AGENT_ENDPOINTS_FEATURE_FLAG_HEADER = 'HostedAgents=V1Preview,AgentEndpoints=V1Preview';
const REQUEST_TIMEOUT_MS = 120_000;
// 20 minutes — toolbox-enabled responses agents (e.g. 04-foundry-toolbox)
// have been observed to take >10 minutes from version creation until session
// readiness on a cold project, especially when multiple PR cells deploy at
// once. The original 10-minute budget exhausted before readiness on those
// cells (~18 attempts × 30s/attempt). Bumping the budget gives the platform
// time to come up before we declare a real failure.
const RETRY_TIMEOUT_MS = 20 * 60_000;
const RETRY_DELAY_MS = 10_000;
const AGENT_VERSION_READY_TIMEOUT_MS = 2 * 60_000;
const AGENT_VERSION_READY_DELAY_MS = 15_000;

interface ResponseApiBody {
    id?: string;
    status?: string;
    error?: { message?: string; code?: string };
    output?: unknown;
    output_text?: string;
}

interface ConversationApiBody {
    id?: string;
}

interface ApiSmokeRequestLog {
    method: string;
    url: string;
    headers: Record<string, string>;
    body?: string;
}

interface ApiSmokeOptions {
    sampleRelativePath?: string;
}

class ApiSmokeHttpError extends Error {
    public constructor(
        public readonly operation: string,
        public readonly status: number,
        public readonly statusText: string,
        public readonly body: string
    ) {
        super(`${operation} -> ${status} ${statusText}${body ? `: ${truncate(body)}` : ''}`);
    }
}

export function readHostedAgentProtocols(workspaceFolder: string): HostedAgentProtocol[] {
    const agentYamlPath = path.join(workspaceFolder, 'agent.yaml');
    const agentYaml = fs.readFileSync(agentYamlPath, 'utf-8');
    const protocols = new Set<HostedAgentProtocol>();

    for (const protocolMatch of agentYaml.matchAll(/^\s*-\s*protocol:\s*([a-zA-Z0-9_-]+)/gm)) {
        const protocol = protocolMatch[1].toLowerCase();
        if (protocol === 'invocations' || protocol === 'responses') {
            protocols.add(protocol);
        }
    }

    return [...protocols];
}

export async function smokeTestDeployedAgentApis(
    agentName: string,
    protocols: HostedAgentProtocol[],
    options: ApiSmokeOptions = {}
): Promise<void> {
    const protocolsToTest = [...new Set(protocols)];
    if (protocolsToTest.length === 0) {
        throw new Error(`No supported protocols found in agent.yaml for ${agentName}.`);
    }

    const target = fixture();
    const connection = projectConnection(target);
    const bearer = await getDataPlaneToken();

    const samplePath = options.sampleRelativePath?.replace(/\\/g, '/').toLowerCase() ?? '';
    // Known-broken on the foundry-extension deploy path: the platform-side
    // Responses host (alpha agent_framework_foundry_hosting) returns an
    // opaque `server_error` for store=true + conversation.id requests
    // against this sample, exhausting the full retry window. Cloud E2E
    // (which sends store=false) passes; deploy itself succeeds. Skip the
    // Responses smoke for this one sample until the upstream SDK is fixed.
    const skipResponsesSmoke =
        samplePath.includes('/agent-framework/responses/04-foundry-toolbox') ||
        samplePath.includes('/langgraph/responses/07-human-in-the-loop');

    let lastError: unknown;
    for (const protocol of protocolsToTest) {
        try {
            if (protocol === 'invocations') {
                await retryTransient(
                    () => smokeInvocationApi(connection, agentName, bearer, options),
                    `Invocation API ${agentName}`
                );
            } else {
                if (skipResponsesSmoke) {
                    // eslint-disable-next-line no-console
                    console.warn(
                        `[api smoke] Skipping Responses API smoke for ${agentName} (sample ${samplePath}): known platform-side server_error in agent_framework_foundry_hosting alpha.`
                    );
                    return;
                }
                await retryTransient(() => smokeResponsesApi(connection, agentName, bearer), `Responses API ${agentName}`);
            }
            return;
        } catch (err) {
            lastError = err;
        }
    }

    throw lastError instanceof Error ? lastError : new Error(`No hosted-agent API smoke test passed for ${agentName}.`);
}

async function getDataPlaneToken(): Promise<string> {
    const tenantId = process.env.AI_FOUNDRY_TENANT_ID ?? process.env.AZURE_TENANT_ID;
    const credential = new DefaultAzureCredential(tenantId ? { tenantId } : undefined);
    const token = await credential.getToken(DATA_PLANE_SCOPE);
    if (!token) {
        throw new Error(`Could not acquire token for ${DATA_PLANE_SCOPE}.`);
    }
    return token.token;
}

async function smokeInvocationApi(
    connection: string,
    agentName: string,
    bearer: string,
    options: ApiSmokeOptions
): Promise<void> {
    const sessionId = randomUUID();
    const prompt = 'hello';

    try {
        const url = endpointUrl(connection, agentName, '/endpoint/protocols/invocations', {
            'api-version': FOUNDRY_API_VERSION,
            agent_session_id: sessionId
        });
        const request: RequestInit = {
            method: 'POST',
            headers: authHeaders(bearer, {
                'Content-Type': 'application/json',
                'Foundry-Features': HOSTED_AGENTS_FEATURE_FLAG_HEADER
            }),
            body: JSON.stringify(invocationSmokeBody(prompt, options.sampleRelativePath))
        };
        const response = await requestText('Invocation API smoke', url, request);

        if (!response.body.trim()) {
            throw new Error('Invocation API smoke returned an empty response body.');
        }

        logApiExchange(agentName, 'Invocation API smoke', toRequestLog(url, request), response);
    } finally {
        await deleteEndpointSession(connection, agentName, sessionId, bearer);
    }
}

function invocationSmokeBody(prompt: string, sampleRelativePath?: string): Record<string, unknown> {
    const normalised = sampleRelativePath?.replace(/\\/g, '/').toLowerCase() ?? '';
    if (normalised.includes('/human-in-the-loop')) {
        return { task: prompt };
    }
    if (normalised.includes('/github-copilot')) {
        return { input: prompt };
    }
    if (normalised.includes('/ag-ui')) {
        return {
            threadId: 'thread-1',
            runId: 'run-1',
            state: {},
            messages: [{ id: 'msg-1', role: 'user', content: prompt }],
            tools: [],
            context: [],
            forwardedProps: {}
        };
    }
    return { message: prompt };
}

async function smokeResponsesApi(connection: string, agentName: string, bearer: string): Promise<void> {
    const sessionId = randomUUID();
    const prompt = 'hello';

    try {
        const conversation = await createEndpointConversation(connection, agentName, bearer);
        const url = endpointUrl(connection, agentName, '/endpoint/protocols/openai/responses', {
            'api-version': FOUNDRY_API_VERSION
        });
        const request: RequestInit = {
            method: 'POST',
            headers: authHeaders(bearer, { 'Content-Type': 'application/json' }),
            body: JSON.stringify({
                conversation: { id: conversation.id },
                input: [
                    {
                        type: 'message',
                        role: 'user',
                        content: [{ type: 'input_text', text: prompt }]
                    }
                ],
                stream: false,
                store: true,
                agent_session_id: sessionId
            })
        };
        const response = await requestText('Responses API smoke', url, request);
        const finalResponse = parseJsonBody<ResponseApiBody>('Responses API smoke', response.body);
        if (finalResponse.error) {
            // eslint-disable-next-line no-console
            console.warn(
                `[api smoke] Responses API returned error for ${agentName}: ${truncate(JSON.stringify(finalResponse), 4_000)}`
            );
        }
        assertResponseSucceeded(finalResponse);

        logApiExchange(agentName, 'Responses API smoke', toRequestLog(url, request), response);
    } finally {
        await deleteEndpointSession(connection, agentName, sessionId, bearer);
    }
}

async function createEndpointConversation(
    connection: string,
    agentName: string,
    bearer: string
): Promise<ConversationApiBody> {
    const conversation = (await requestJson(
        'Responses conversation create',
        endpointUrl(connection, agentName, '/endpoint/protocols/openai/conversations', {
            'api-version': FOUNDRY_API_VERSION
        }),
        {
            method: 'POST',
            headers: authHeaders(bearer, {
                'Content-Type': 'application/json',
                'Foundry-Features': HOSTED_AGENTS_FEATURE_FLAG_HEADER
            }),
            body: JSON.stringify({})
        }
    )) as ConversationApiBody;

    if (!conversation.id) {
        throw new Error(`Responses conversation create did not return an id: ${truncate(JSON.stringify(conversation))}`);
    }

    return conversation;
}

function assertResponseSucceeded(response: ResponseApiBody): void {
    if (!response.id) {
        throw new Error(`Responses API smoke did not return a response id: ${truncate(JSON.stringify(response))}`);
    }
    if (response.error) {
        throw new Error(
            `Responses API smoke returned error ${response.error.code ?? '<none>'}: ${response.error.message ?? '<none>'}`
        );
    }

    const status = response.status?.toLowerCase();
    if (status && status !== 'completed') {
        throw new Error(`Responses API smoke did not complete. status=${status} body=${truncate(JSON.stringify(response))}`);
    }
}

async function requestJson(operation: string, url: string, init: RequestInit): Promise<unknown> {
    const response = await requestText(operation, url, init);
    return parseJsonBody(operation, response.body);
}

function parseJsonBody<T>(operation: string, body: string): T {
    try {
        return JSON.parse(body) as T;
    } catch (err) {
        throw new Error(`${operation} returned non-JSON body: ${truncate(body)} (${(err as Error).message})`);
    }
}

async function requestText(operation: string, url: string, init: RequestInit): Promise<{ status: number; body: string }> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    let response: Response;
    try {
        response = await fetch(url, { ...init, signal: controller.signal });
    } finally {
        clearTimeout(timeout);
    }

    const body = await response.text();
    if (!response.ok) {
        throw new ApiSmokeHttpError(operation, response.status, response.statusText, body);
    }

    return { status: response.status, body };
}

async function deleteEndpointSession(
    connection: string,
    agentName: string,
    sessionId: string,
    bearer: string
): Promise<void> {
    const url = endpointUrl(connection, agentName, `/endpoint/sessions/${encodeURIComponent(sessionId)}`, {
        'api-version': FOUNDRY_API_VERSION
    });
    const response = await fetch(url, {
        method: 'DELETE',
        headers: authHeaders(bearer, { 'Foundry-Features': AGENT_ENDPOINTS_FEATURE_FLAG_HEADER })
    });
    if (!response.ok && response.status !== 404) {
        const body = await response.text();
        // eslint-disable-next-line no-console
        console.warn(`[api smoke] Could not delete endpoint session ${agentName}/${sessionId}: ${response.status} ${body}`);
    }
}

function endpointUrl(connection: string, agentName: string, pathSuffix: string, query: Record<string, string>): string {
    const url = new URL(`${connection}/agents/${encodeURIComponent(agentName.trim())}${pathSuffix}`);
    for (const [name, value] of Object.entries(query)) {
        url.searchParams.set(name, value);
    }
    return url.toString();
}

function authHeaders(bearer: string, extra: Record<string, string> = {}): Record<string, string> {
    return {
        Authorization: `Bearer ${bearer}`,
        ...extra
    };
}

function toRequestLog(url: string, request: RequestInit): ApiSmokeRequestLog {
    return {
        method: request.method ?? 'GET',
        url,
        headers: redactHeaders(request.headers),
        body: typeof request.body === 'string' ? request.body : undefined
    };
}

function redactHeaders(headers: RequestInit['headers']): Record<string, string> {
    const output: Record<string, string> = {};
    for (const [name, value] of Object.entries((headers ?? {}) as Record<string, string>)) {
        output[name] = name.toLowerCase() === 'authorization' ? '<redacted>' : value;
    }
    return output;
}

function logApiExchange(
    agentName: string,
    operation: string,
    request: ApiSmokeRequestLog,
    response: { status: number; body: string }
): void {
    // eslint-disable-next-line no-console
    console.log(
        `[api smoke] ${operation} passed for ${agentName}\n` +
            `request: ${formatJsonForLog(request)}\n` +
            `response: ${formatJsonForLog({ status: response.status, body: formatBodyForLog(response.body) })}`
    );
}

function formatJsonForLog(value: unknown): string {
    return truncate(JSON.stringify(value, undefined, 2), 4_000);
}

function formatBodyForLog(body: string): unknown {
    try {
        return JSON.parse(body);
    } catch {
        return body;
    }
}

async function retryTransient<T>(operation: () => Promise<T>, label: string): Promise<T> {
    const transientDeadline = Date.now() + RETRY_TIMEOUT_MS;
    const agentVersionReadyDeadline = Date.now() + AGENT_VERSION_READY_TIMEOUT_MS;
    let attempt = 0;
    let lastError: unknown;

    while (true) {
        attempt++;
        try {
            return await operation();
        } catch (err) {
            lastError = err;
            const isWaitingForAgentVersion = isAgentVersionNotReadyError(err);
            const retryDeadline = isWaitingForAgentVersion ? agentVersionReadyDeadline : transientDeadline;
            const retryDelayMs = isWaitingForAgentVersion ? AGENT_VERSION_READY_DELAY_MS : RETRY_DELAY_MS;

            if (!isRetryable(err) || Date.now() + retryDelayMs >= retryDeadline) {
                throw err;
            }
            // eslint-disable-next-line no-console
            console.warn(formatRetryMessage(label, attempt, err, isWaitingForAgentVersion, retryDelayMs));
            await delay(retryDelayMs);
        }
    }

    throw lastError instanceof Error ? lastError : new Error(`${label} failed after retries.`);
}

function isRetryable(err: unknown): boolean {
    if (err instanceof ApiSmokeHttpError) {
        // 412 = Precondition Failed, returned as precondition_failed when
        //   the platform sees a concurrent edit on the agent/session
        //   resource (a benign race during deploy + smoke).
        // 424 = Failed Dependency, returned as session_not_ready while the
        // agent container is still warming up. Treat them as transient just
        // like 5xx so newly-deployed samples don't fail the smoke test.
        return isAgentVersionNotReady(err) || [408, 409, 412, 424, 425, 429, 500, 502, 503, 504].includes(err.status);
    }
    if (err instanceof Error && err.name === 'AbortError') {
        return true;
    }
    // The Responses API can return HTTP 200 with a JSON body containing
    // {"error": {"code": "server_error", ...}}. assertResponseSucceeded
    // throws a plain Error in that case; treat it as transient too so we
    // give the platform a chance to recover before failing the smoke run.
    if (err instanceof Error && /returned error server_error/i.test(err.message)) {
        return true;
    }
    return false;
}

function isAgentVersionNotReadyError(err: unknown): boolean {
    return err instanceof ApiSmokeHttpError && isAgentVersionNotReady(err);
}

function formatRetryMessage(
    label: string,
    attempt: number,
    err: unknown,
    isWaitingForAgentVersion: boolean,
    retryDelayMs: number
): string {
    const reason = err instanceof Error ? err.message : String(err);
    if (isWaitingForAgentVersion) {
        return `[api smoke] ${label} attempt ${attempt} found agent version not ready; waiting ${retryDelayMs / 1000}s before retrying: ${reason}`;
    }
    return `[api smoke] ${label} attempt ${attempt} failed; retrying: ${reason}`;
}

function isAgentVersionNotReady(err: ApiSmokeHttpError): boolean {
    return err.status === 400 && err.body.toLowerCase().includes('agent_version_not_ready');
}

function delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function truncate(value: string, maxLength = 1_000): string {
    const normalized = value.replace(/\s+/g, ' ').trim();
    if (normalized.length <= maxLength) {
        return normalized;
    }
    return `${normalized.slice(0, maxLength)}...`;
}
