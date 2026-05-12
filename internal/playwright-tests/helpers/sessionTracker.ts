/**
 * File-backed tracker for deployed agents that need cleanup at teardown.
 *
 * Records are appended on write. The file is intentionally inside
 * `.vscode-test/` so it's gitignored; it survives between runs only by being
 * explicitly cleared at the start of each global setup.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';

const STATE_FILE = path.join(__dirname, '..', '.vscode-test', 'created-artefacts.json');

export interface AgentRecord {
    kind: 'agent';
    agentName: string;
    capturedAt: string;
}

interface PersistedFile {
    records: AgentRecord[];
}

function readFile(): PersistedFile {
    if (!fs.existsSync(STATE_FILE)) {
        return { records: [] };
    }
    try {
        return JSON.parse(fs.readFileSync(STATE_FILE, 'utf-8')) as PersistedFile;
    } catch {
        return { records: [] };
    }
}

function writeFile(data: PersistedFile): void {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(data, null, 2));
}

export function clearTracker(): void {
    writeFile({ records: [] });
}

export function recordDeployedAgent(agentName: string): void {
    const data = readFile();
    if (data.records.some((r) => r.agentName === agentName)) {
        return;
    }
    data.records.push({ kind: 'agent', agentName, capturedAt: new Date().toISOString() });
    writeFile(data);
}

export function readDeployedAgents(): AgentRecord[] {
    return readFile().records.filter((r): r is AgentRecord => r.kind === 'agent');
}
