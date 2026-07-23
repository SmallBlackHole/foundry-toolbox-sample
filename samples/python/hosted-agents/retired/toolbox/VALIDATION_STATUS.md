# Toolbox Tools — Validation Status

Tracks which `tools/*.md` scenarios have been validated end-to-end (connection + toolbox created, then tool discovered via `tools/list` and invoked via `tools/call`).

**Last validated:** 2026-07-21 · project `xiaofhua-eastus2` (eastus2) · azd 1.28.0

## Validation rule

A tool counts as **✅ Validated only when a real `tools/call` succeeds** — i.e. the JSON-RPC
response has `result.isError == false` (or, for MCP-backed tools, returns actual content with no
error) and contains genuine tool output. The full bar is:

1. Toolbox created (via `azd ai toolbox` CLI or REST).
2. `tools/list` enumerates the expected tool(s) — **necessary but not sufficient**.
3. `tools/call` **succeeds** and returns real output.

Enumeration alone (step 2) does **not** qualify — a tool that lists but errors on call is **⚠️
Blocked**, not Validated. Record the concrete call result in the Notes column (e.g. `print(2+2) → 4`,
`docs_search returned real docs`).

## Authoring styles (two ways to create a toolbox)

The toolbox README documents two CLI styles. They are tracked separately here because they exercise different code paths.

| Style | How toolbox is created | Status |
|-------|------------------------|--------|
| **Way A — `toolbox.yaml` (standalone)** | `azd ai toolbox create --from-file toolbox.yaml` | ✅ Validated (this is what the per-tool table below covers) |
| **Way B — `azure.yaml` (declared with agent)** | `host: azure.ai.toolbox` service, upserted by `azd deploy`; agent references it by `TOOLBOX_NAME` | ✅ Validated (see "Way B validation" section below) |

The per-tool table below reflects **Way A** results. The 04 sample ships a Way A `toolbox.yaml` and does **not** declare a toolbox service in its `azure.yaml`.

## Summary (Way A)

**8 of 15 validated.**

| # | Tool doc | Status | Notes |
|---|----------|--------|-------|
| 1 | web-search.md | ✅ Validated | `web_search` called, returned real web answer. Arg name: `search_query`. |
| 2 | file-search.md | ✅ Validated | Created vector store + uploaded/indexed file; `file_search` retrieved planted content. Arg name: `queries` (array). |
| 3 | code-interpreter.md | ✅ Validated | `print(2+2)` → `4`. Arg name: `code`. |
| 4 | mcp-noauth.md | ✅ Validated (CLI) | Microsoft Learn MCP (`https://learn.microsoft.com/api/mcp`). Full `azd ai toolbox` CLI lifecycle (create/list/show/delete) run; `microsoft_docs_search` returned real docs. |
| 5 | mcp-key-auth.md | ✅ Validated (CLI) | GitHub MCP (`https://api.githubcopilot.com/mcp`) via `ghmcppat` CustomKeys connection (PAT as `Authorization=Bearer`). 47 tools enumerated; `github___get_me` returned the authed user. |
| 6 | mcp-oauth-managed.md | ⚠️ Blocked (gateway) | Config + consent flow correct: `ghmcpoauth` (OAuth2, connector `foundrygithubmcp`) created; `tools/call` returned MCP `-32006` + consent URL as documented; browser consent completed. But afterward both raw REST **and** `azd ai agent invoke` fail with `Failed to exchange ConnectorGateway token: Forbidden` — the APIM connector gateway won't issue a token for this identity. Env/connector-provisioning gap, not a doc/CLI error. |
| 7 | mcp-oauth-custom.md | ⬜ Not tested | |
| 8 | mcp-agent-identity.md | ⚠️ Blocked | `language-mcp` created, but `tools/list` → HTTP 401 PermissionDenied. Project MI lacks RBAC on the Azure Language MCP endpoint. Env RBAC gap, not a doc/CLI error. |
| 9 | mcp-1p-obo.md | ✅ Validated | `foundry-mcp` (`https://mcp.ai.azure.com`); `model_catalog_list` returned catalog. |
| 10 | azure-ai-search.md | ⬜ Not tested | |
| 11 | a2a.md | ⬜ Not tested | |
| 12 | bing-custom-search.md | ⬜ Not tested | |
| 13 | openapi.md | ✅ Validated (CLI) | Anonymous OpenAPI (inline Cat Facts spec, `catfact.ninja`); `catfacts___getFact` returned a real fact. |
| 14 | browser-automation.md | ⬜ Not tested | |
| 15 | multi-tool.md | ✅ Validated | Multiple tools behind one toolbox endpoint enumerated + called together. |

Legend: ✅ validated · ⚠️ blocked (env/RBAC, not doc) · ⬜ not tested

## Way B validation (`azure.yaml` toolbox service)

**✅ Validated end-to-end 2026-07-21.** Provisioned a fresh project, upserted the toolbox declared in `azure.yaml`, called its tools, then deleted the resource group.

### What Way B is

Instead of creating the toolbox standalone (Way A), you declare it **inside `azure.yaml`** as a `host: azure.ai.toolbox` service alongside the agent. The agent then references it by `TOOLBOX_NAME` and `azd` manages its lifecycle. The `azure.yaml` needs three service blocks:

- `host: azure.ai.project` — the project + model deployment
- `host: azure.ai.connection` — any connection the toolbox tools need (e.g. `foundrymcpconn`)
- `host: azure.ai.toolbox` — the toolbox itself, whose `tools:` list mirrors a Way A `toolbox.yaml`, with `uses:` pointing at the project + connections

### The working command sequence (important — order matters)

```bash
# 1. Provision infra ONLY (AI Services account + project + model deployment).
#    This does NOT create the toolbox or connection yet.
azd provision

# 2. Create any UserEntraToken (Entra pass-through) connection BY HAND first.
#    azd will NOT create these for you (see gotcha #3 below).
azd ai connection create foundrymcpconn --kind remote-tool \
  --target https://mcp.ai.azure.com --auth-type user-entra-token \
  --audience https://mcp.ai.azure.com -p <project-endpoint>

# 3. Deploy the toolbox service — THIS is the step that upserts the toolbox.
azd deploy <toolbox-service-name>       # e.g. agent-tools-b
```

Then the toolbox is live at `<project-endpoint>/toolboxes/<name>/mcp?api-version=v1`.

### Why the order matters — three non-obvious traps

The READMEs don't spell these out; each one produced a hard failure until worked around:

1. **`azd provision` does NOT create the toolbox.** It only creates ARM infra (AI Services account, project, model deployment). Right after `azd provision`, `azd ai toolbox list` is **empty**. The toolbox is created later, by `azd deploy`. (And `azd deploy` *before* `azd provision` fails with "infrastructure has not been provisioned".)

2. **`azd deploy <toolbox>` does NOT create its connection first.** The toolbox `uses:` a connection, but deploying the toolbox fails with `connection "<name>" was not found on the project` unless the connection already exists. Create the connection before deploying the toolbox.

3. **Entra pass-through (`UserEntraToken`) connections are never auto-created.** Running `azd deploy <connection-service>` on such a connection just prints *"uses user-entra-token auth provisioned elsewhere; skipping deploy upsert"* and creates nothing. You must create it out-of-band with `azd ai connection create ... --auth-type user-entra-token` (step 2 above).

### Provisioning gotchas (environment, not doc bugs)

- **Model quota:** `azd provision` deploys the whole `azure.yaml` as one ARM template and always requests **new** capacity for the model deployment — it does **not** detect an existing same-named deployment. If that model's quota is maxed it fails `InsufficientQuota`. Seen with `gpt-5.4-mini` (0 quota) and `gpt-4.1-mini` (2550/2550 used); switching to `gpt-5-mini` (free quota) unblocked it.
- **Resource group location:** reusing an existing RG whose location differs from `AZURE_LOCATION` fails with `InvalidResourceGroupLocation` (RG `foundry-toolbox` was westus2 while location was eastus2). Let `azd` create its own RG, or match the location.

### This run's evidence

Provisioned project `04-foundry-toolbox` (RG `rg-04-toolbox-b-test`, eastus2, model `gpt-5-mini`) with toolbox `agent-tools-b` (web_search + code_interpreter + noauth_mcp + foundry-mcp). Toolbox reached default version 1 and enumerated all tools; `code_interpreter` `print(6*7)` → `42`; foundry-mcp (Entra pass-through) and noauth_mcp both responded. Resource group deleted afterward; the 04 sample's `azure.yaml` was restored (it ships Way A only).

## CLI notes found during validation

- `-p` is a shorthand for `--project-endpoint` on `azd ai connection create`, but **not** on `azd ai toolbox create/delete/show` (long form only).
- Run `azd ai toolbox` commands from the sample directory (one containing `azure.yaml`); running elsewhere fails with "no project exists".
- The README's "one failing MCP source fails the whole `tools/list`" behavior is real (confirmed via the `language-mcp` 401).
- **Non-interactive shells:** `azd ai toolbox ...` (the wrapper) fails with `AzureDeveloperCLICredential: please run "azd auth login"` in a non-TTY shell, even when logged in — the azd wrapper injects a stale `AZD_ACCESS_TOKEN` the extension rejects. Workaround: invoke the extension binary **directly** (`~/.azd/extensions/azure.ai.toolboxes/azure-ai-toolboxes-*.exe create|list|show|delete ...`), which uses the fresh `~/.azd` login and works. The `azd ai toolbox ...` form itself works fine in a normal interactive terminal.
