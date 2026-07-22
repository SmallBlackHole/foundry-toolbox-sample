# Foundry Toolbox — User Guide

A **toolbox** is a managed Microsoft Foundry resource: you define a curated set of tools once,
manage them centrally, and expose them through a **single MCP-compatible endpoint** that any agent
can consume. Foundry handles credential injection, token refresh, OAuth consent, and enterprise
policy at runtime — so you can add, remove, or reconfigure tools **without changing agent code**.

> **Toolbox vs. connection.** A **connection** stores the authentication details for one external
> service (an MCP server, a search index, an API). A **toolbox** bundles one or more tools — some
> connectionless (web search, code interpreter), some backed by a connection — behind one endpoint.
> Connection-backed tools reference their connection by name; the toolbox uses it to authenticate
> tool calls at runtime.

This guide shows how to create tool connections and toolboxes for **every supported scenario**,
across every surface (CLI, portal, VS Code). For each tool, jump to its page in the
[scenario index](#scenario-index).

---

## Prerequisites

1. **RBAC** — the calling identity (you as developer, and the agent's identity at runtime) needs
   **Foundry User** on the Foundry project. Grant it at project scope if missing. (`Azure AI
   Developer` or `Cognitive Services Contributor` also work.)
2. **CLI (for the CLI ways)** — install the unified Foundry extension bundle once:
   ```bash
   azd ext install microsoft.foundry
   azd auth login
   ```

---

## Three ways to create a toolbox

You can create connections and toolboxes on three surfaces. Pick whichever fits your workflow —
they produce the same resource.

| Way | Surface | Best when |
|-----|---------|-----------|
| **CLI** | `azd ai` commands | Repeatable, scriptable, checked into source control alongside the agent. |
| **Portal** | Foundry portal (ai.azure.com) + Azure portal (portal.azure.com) | Exploring, one-off setup, or you prefer clicking. |
| **VS Code extension** | Microsoft Foundry Toolkit | You author your agent in VS Code and want tools/toolboxes in the same place. |

### The CLI has two authoring styles

Within the CLI way, there are two file styles — pick one:

- **Way A — `toolbox.yaml` (standalone).** Define the tools in a `toolbox.yaml` file and create the
  toolbox explicitly:
  ```bash
  azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
  ```
  Then read its MCP endpoint and wire it into the agent as `TOOLBOX_ENDPOINT`. Best when the
  toolbox is **shared across agents** or managed on its own lifecycle.

- **Way B — `azure.yaml` (declared with the agent).** Declare the toolbox as a
  `host: azure.ai.toolbox` service in the same `azure.yaml` as your agent; `azd deploy` upserts it
  and the agent references it **by name** (`TOOLBOX_NAME`), resolving the endpoint at runtime. Best
  when the toolbox is **provisioned together with one agent**.

Each scenario page below shows both styles.

### The portal flow (Foundry portal)

In the [Foundry portal](https://ai.azure.com/), toolboxes live under **Tools → Toolboxes**. Click
**Create toolbox**, give it a **Name**, then under **Included** click **+ Add → Add tool** to open
the **Select a tool** dialog. That dialog has three tabs:

| Tab | What it holds |
|-----|---------------|
| **Configured** | Built-in Foundry tools — Web search, Code interpreter, File search, Azure AI Search, Browser automation, etc. Select the tile and fill its tool-specific config. |
| **Catalog** | Pre-integrated MCP servers from the Foundry Tool Catalog — GitHub, Azure MCP, MongoDB, Dataverse, and more. Search, select, and fill only the credential (endpoint + auth are pre-set). **Prefer this over hand-building an MCP connection** when the server you want is listed. |
| **Custom** | Bring-your-own endpoints — **MCP server** (any remote MCP URL + auth mode), **OpenAPI tool** (inline 3.x spec), **A2A** (remote agent endpoint). Use when the server isn't in the Catalog. |

For connection-backed tools, the config dialog offers **Connect to a new resource** / **Create a
new connection** inline — no separate Management page needed. Where a brand-new Azure resource is
required (Azure AI Search service, Bing Grounding account, Playwright workspace), a **Create a new
resource** link opens the Azure portal create wizard. Finish by clicking **Publish**; the toolbox
detail page then shows the consumer MCP endpoint to copy into `TOOLBOX_ENDPOINT`.

**MCP authentication modes** (in the Custom-tab MCP dialog's **Authentication** dropdown):

| Portal option | Meaning |
|---------------|---------|
| **Key-based** | Static key/header (e.g. `Authorization: Bearer <token>`). |
| **OAuth Identity Passthrough** | OAuth2 with your app registration — the dialog collects **Client ID, Client secret, Token URL, Auth URL, Scopes**. |
| **Microsoft Entra** | Entra token auth. A **Type** sub-dropdown chooses **Agent Identity** or **Project Managed Identity**; both take an **Audience** (no secret). |
| **Unauthenticated** | Public server, no credentials. |

---

## Connections at a glance

Connectionless tools need no connection; the rest do. Which auth mode a tool uses determines the
connection you create.

| Tool | Auth mode | Connection required? |
|------|-----------|----------------------|
| Web search (basic Bing) | — | No |
| Code interpreter | — | No |
| File search | — | No (vector store lives in the project) |
| MCP — no auth | None | No |
| MCP — key auth | `CustomKeys` | Yes |
| MCP — OAuth (managed) | `OAuth2` (Foundry-managed) | Yes (no client secret — Foundry owns the app) |
| MCP — OAuth (custom app) | `OAuth2` (bring-your-own) | Yes |
| MCP — agent identity | `AgenticIdentity` | Yes |
| MCP — Entra passthrough | `UserEntraToken` | Yes |
| Azure AI Search | `ApiKey` | Yes |
| A2A (agent-to-agent) | `None` / `RemoteA2A` | Yes (target endpoint) |
| Bing Custom Search | `ApiKey` (`GroundingWithCustomSearch`) | Yes |
| OpenAPI | anonymous / `CustomKeys` / managed identity | Conditional |
| Browser automation | `ProjectManagedIdentity` | Yes (Playwright workspace) |

---

## Scenario index

Each page is self-contained: what the tool does, the connection it needs, and how to create the
toolbox via **CLI (both styles)**, **portal**, and **VS Code**.

| # | Scenario | Page |
|---|----------|------|
| 1 | Web search (basic Bing) | [tools/web-search.md](tools/web-search.md) |
| 2 | File search (vector store) | [tools/file-search.md](tools/file-search.md) |
| 3 | Code interpreter | [tools/code-interpreter.md](tools/code-interpreter.md) |
| 4 | MCP — no auth (public server) | [tools/mcp-noauth.md](tools/mcp-noauth.md) |
| 5 | MCP — key auth (GitHub PAT) | [tools/mcp-key-auth.md](tools/mcp-key-auth.md) |
| 6 | MCP — OAuth (managed connector) | [tools/mcp-oauth-managed.md](tools/mcp-oauth-managed.md) |
| 7 | MCP — OAuth (custom app) | [tools/mcp-oauth-custom.md](tools/mcp-oauth-custom.md) |
| 8 | MCP — agent identity | [tools/mcp-agent-identity.md](tools/mcp-agent-identity.md) |
| 9 | MCP — Entra passthrough | [tools/mcp-entra-passthrough.md](tools/mcp-entra-passthrough.md) |
| 10 | Azure AI Search | [tools/azure-ai-search.md](tools/azure-ai-search.md) |
| 11 | A2A (agent-to-agent) | [tools/a2a.md](tools/a2a.md) |
| 12 | Bing Custom Search | [tools/bing-custom-search.md](tools/bing-custom-search.md) |
| 13 | OpenAPI | [tools/openapi.md](tools/openapi.md) |
| 14 | Browser automation | [tools/browser-automation.md](tools/browser-automation.md) |
| 15 | Multi-tool toolbox | [tools/multi-tool.md](tools/multi-tool.md) |

---

## Versions & endpoints

- **Versions are immutable snapshots.** Every change produces a new version. A toolbox has a
  **default version**, which the consumer endpoint serves.
- Creating a version does **not** auto-promote it — except the **first** version of a new toolbox,
  which is auto-promoted. Promote later versions with
  `azd ai toolbox publish <name> <version>`.

| Role | Endpoint | Use |
|------|----------|-----|
| **Consumer** | `{project_endpoint}/toolboxes/{toolbox_name}/mcp?api-version=v1` | Connect agents. Always serves the default version. |
| **Developer** | `{project_endpoint}/toolboxes/{toolbox_name}/versions/{version}/mcp?api-version=v1` | Test a specific version before promoting. |

- `?api-version=v1` is **required** (otherwise HTTP 400).
- Auth: bearer token with scope `https://ai.azure.com/.default`.
- Connect agents to the **consumer** endpoint so promoting a new version needs no redeploy.

## Composition rule (multiple tools in one toolbox)

**Across the whole toolbox, at most ONE tool may be unnamed.** Every other tool needs a `name`
(built-ins / `openapi`) or `server_label` (`mcp`). Violating this returns
`400 invalid_payload: Multiple tools without identifiers found`. See
[tools/multi-tool.md](tools/multi-tool.md).

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `403 Forbidden` on create | Caller lacks **Foundry User** on the project — grant it at project scope. |
| `TOOLBOX_ENDPOINT` not set | Run `azd ai toolbox show <name>` and copy the endpoint into the agent's env. |
| `tools/list` returns zero | Version still provisioning, or the tool type isn't available in the region — wait ~10 s and retry, or try another region. |
| `tools/list` returns zero for MCP/A2A only | Bad or missing connection credentials — verify the connection exists and creds are correct. |
| `400 Multiple tools without identifiers found` | Two unnamed tools in one toolbox — name every tool but one. |

## References

- [Toolbox (how-to)](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/toolbox)
- [Tool Catalog](https://learn.microsoft.com/azure/foundry/agents/concepts/tool-catalog)
- [Foundry Toolkit (VS Code)](https://code.visualstudio.com/docs/intelligentapps/tool-catalog)
- [Foundry portal](https://ai.azure.com/)
