# Hosted-agent sample deploy tests

End-to-end Playwright suite that validates every hosted-agent sample under
`samples/python/hosted-agents/**` and `samples/csharp/hosted-agents/**`
deploys cleanly via the **AI Foundry VS Code extension**.

For each sample the test:

1. Copies the sample directory into an empty per-test temp workspace.
2. Rewrites `name:` in `agent.yaml` to a unique `pw-` prefixed value so runs
   don't collide with each other or with shared deployments.
3. Launches its own VS Code instance with that workspace folder.
4. Runs `Microsoft Foundry: Deploy Hosted Agent`, accepting Quick Pick
   defaults at every step.
5. Verifies the playground auto-opens and shows the deployed agent.
6. Cleans up the deployed agent and the temp workspace.

Tests run **serially** (`workers: 1`, `fullyParallel: false`) because each
sample triggers a remote ACR build + agent create flow that takes several
minutes; running them in parallel produces noisy timeouts without saving
wall-clock time on a single machine.

## Prerequisites

1. **Azure sign-in.** Run `az login`. `DefaultAzureCredential` picks up
   `az login` locally, or service principal env vars on CI.
2. **A pre-configured Foundry project.** The project / account / RG /
   subscription / location are derived from the project ARM URI; the test
   harness sets `AI_FOUNDRY_ENVIRONMENT=test` and
   `AI_FOUNDRY_HEADLESS_AUTH=true` so the extension's
   `TestDefaultProjectService` and `TestAuthenticationService` swap in and
   no interactive sign-in is required.
3. **Suite deps.**

```pwsh
cd internal/playwright-tests
npm install
npx playwright install chromium
```

The AI Foundry extension itself is installed from the VS Code marketplace
(`TeamsDevApp.vscode-ai-foundry`) into a per-suite extensions dir. The launcher
uses `--force` on every marketplace-mode launch so reused local test profiles
refresh to the latest available marketplace version unless a version is pinned.

Alternative install modes:

- **From VSIX**: set `AI_FOUNDRY_EXTENSION_VSIX` to an absolute path of a
  `.vsix` file (e.g. a CI build artifact).
- **From local build**: set `AI_FOUNDRY_EXTENSION_PATH` to the root of a
  built `ai-foundry-for-vscode` working tree.

See [Configuration](#configuration) for details.

## Running

```pwsh
# Default: every sample under samples/{python,csharp}/hosted-agents/
npx playwright test

# Single language
npx playwright test --project=python-hosted-agents
npx playwright test --project=csharp-hosted-agents

# Filter samples by relative path (regex). These accept Node regex syntax.
$env:FOUNDRY_SAMPLES_INCLUDE = 'hello-world'
npx playwright test

$env:FOUNDRY_SAMPLES_EXCLUDE = 'workflows|toolbox'
npx playwright test

# View HTML report after a run
npx playwright show-report
```

## Configuration

One value is required; the rest are optional. On first run with a TTY,
you're prompted for the required value and the answer is persisted to
`.env.local` (gitignored).

| Variable                    | Required | Description                                                                                                                                  |
| --------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `AI_FOUNDRY_PROJECT_URI`    | yes      | ARM resource path of the Foundry project. A leading `/resource` is OK.                                                                       |
| `AI_FOUNDRY_EXTENSION_VSIX` | no       | Absolute path to a `.vsix` file to install instead of the marketplace version. Takes priority over marketplace.                              |
| `AI_FOUNDRY_EXTENSION_PATH` | no       | Absolute path to a built `ai-foundry-for-vscode` working tree (`--extensionDevelopmentPath`). Takes priority over both VSIX and marketplace. |

**Optional:**

| Variable                                | Description                                                                                                                    |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `AI_FOUNDRY_TENANT_ID`                  | Override credential tenant.                                                                                                    |
| `AI_FOUNDRY_EXTENSION_VERSION`          | Pin a specific marketplace version of `TeamsDevApp.vscode-ai-foundry` (e.g. `0.5.0`). Leave unset to install/update to latest. |
| `AI_FOUNDRY_PLAYWRIGHT_CDP_PORT`        | CDP port for the per-test VS Code instances (default 9233).                                                                    |
| `AI_FOUNDRY_PLAYWRIGHT_VSCODE_VERSION`  | VS Code version to download (default `stable`).                                                                                |
| `AI_FOUNDRY_PLAYWRIGHT_NO_PRIVATE_DBUS` | Linux CI only; set to `1` to skip the private D-Bus session used for VS Code launches.                                         |
| `FOUNDRY_SAMPLES_INCLUDE`               | Regex; only samples whose relative path matches are kept.                                                                      |
| `FOUNDRY_SAMPLES_EXCLUDE`               | Regex; samples whose relative path matches are dropped.                                                                        |

**CI (non-TTY):** export `AI_FOUNDRY_PROJECT_URI` plus `AZURE_CLIENT_ID`,
`AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` for service principal auth.

## Cleanup

Every deployed agent is recorded in `.vscode-test/created-artefacts.json` via
`helpers/sessionTracker.ts`. Global setup runs `cleanupTrackedArtefacts()`
before clearing the tracker — this catches leftovers from previously aborted
runs. End-of-run teardown deletes the current run's agents. All cleanup is
best-effort: errors are logged and swallowed.

## Troubleshooting

- **Marketplace install failed.** Check network / proxy. To pin a known-good
  version, set `AI_FOUNDRY_EXTENSION_VERSION`. To bypass marketplace, set
  `AI_FOUNDRY_EXTENSION_VSIX` to a `.vsix` file or
  `AI_FOUNDRY_EXTENSION_PATH` to a local build.
- **Local extension build artefacts are missing.** Run
  `npm run build:playwright` from the `ai-foundry-for-vscode` repo root, or
  unset `AI_FOUNDRY_EXTENSION_PATH` to fall back to marketplace.
- **CDP port already in use.** Set `AI_FOUNDRY_PLAYWRIGHT_CDP_PORT` to a
  free port.
- **Auth failures.** Re-run `az login`. For CI, verify the service principal
  env vars are exported.
- **Wrong tenant.** Set `AI_FOUNDRY_TENANT_ID` or `az login --tenant <id>`.
- **Stale tracker.** Delete `.vscode-test/created-artefacts.json`.
- **Quick Pick command title changed.** If the AI Foundry extension renames
  `Microsoft Foundry: Deploy Hosted Agent`, update the corresponding
  `runCommand(...)` calls in `specs/deploySamples.spec.ts`.

## File layout

```
internal/playwright-tests/
├── playwright.config.ts          # Project definitions
├── fixtures/
│   ├── target.ts                 # Project URI → env vars; optional local extension path
│   ├── configPrompt.ts           # First-run prompt, persists to .env.local
│   ├── globalSetup.ts            # Pre/post-run cleanup
│   ├── vscodeLauncher.ts         # @vscode/test-electron + CDP + marketplace install
│   ├── tempWorkspace.ts          # Copy sample + rewrite agent name
│   └── sessionTeardown.ts        # REST-based deletion of tracked agents
├── helpers/
│   ├── attachWebview.ts          # OOPIF-aware playground frame discovery
│   ├── workbench.ts              # Command palette + Quick Pick helpers
│   ├── sessionTracker.ts         # File-backed agent tracker for cleanup
│   └── sampleDiscovery.ts        # Walk samples/ for agent.yaml + Dockerfile
└── specs/
    └── deploySamples.spec.ts     # Parameterized over discovered samples
```
