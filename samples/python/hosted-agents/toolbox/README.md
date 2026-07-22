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
across every surface (CLI, portal, VS Code). For each tool, jump to its page from the
[Tool types](#tool-types) table.

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

For the **Authentication** dropdown options and what each means, see
[MCP authentication](#mcp-authentication) — it maps every portal option to its
stored `authType` and scenario page.

---

## Tool types

Every tool in a toolbox is one of **four types**. This table covers what each is, whether it needs a
connection, and links to each tool's page. MCP is the only type with multiple auth modes — those are
detailed in [MCP authentication](#mcp-authentication) below.

| Tool type | Tool | Connection? | Page |
|-----------|------|-------------|------|
| **Built-in** | Web search (basic Bing) | No | [web-search.md](tools/web-search.md) |
| **Built-in** | Code interpreter | No | [code-interpreter.md](tools/code-interpreter.md) |
| **Built-in** | File search (vector store) | No (store lives in the project) | [file-search.md](tools/file-search.md) |
| **Built-in** | Azure AI Search | Yes | [azure-ai-search.md](tools/azure-ai-search.md) |
| **Built-in** | Bing Custom Search | Yes | [bing-custom-search.md](tools/bing-custom-search.md) |
| **Built-in** | Browser automation | Yes | [browser-automation.md](tools/browser-automation.md) |
| **MCP connection** | Remote MCP server (your own or catalog) | Yes (except no-auth) | [MCP authentication](#mcp-authentication) |
| **A2A connection** | Remote agent (Agent-to-Agent) | Yes | [a2a.md](tools/a2a.md) |
| **OpenAPI connection** | External REST API (OpenAPI 3.x spec) | Conditional | [openapi.md](tools/openapi.md) |

### MCP authentication

An MCP server's auth options depend on **who owns it**. Own it → you pick the mode (A). Catalog
server → the catalog fixes the mode (B).

#### A. Your own MCP server (you choose)

You bring the endpoint and pick one mode.

| Mode | `authType` | Acts as | You provide | Page |
|------|-----------|---------|-------------|------|
| **No auth** | `None` | anonymous | nothing | [mcp-noauth.md](tools/mcp-noauth.md) |
| **Key auth** | `CustomKeys` | a shared static key | a header key/value (e.g. `Authorization: Bearer <token>`) | [mcp-key-auth.md](tools/mcp-key-auth.md) |
| **OAuth — custom** | `OAuth2` | the **calling user** (via *your* OAuth app) | Client ID/secret, Auth/Token/Refresh URLs, Scopes, + register Foundry's reply URL on your app | [mcp-oauth-custom.md](tools/mcp-oauth-custom.md) |
| **Agent identity / project MI** | `AgenticIdentityToken` / `ProjectManagedIdentity` | a Foundry-managed identity (app-only) — the **agent's own** or the **shared project** identity | an `audience` + an RBAC role on the target | [mcp-agent-identity.md](tools/mcp-agent-identity.md) |

Agent identity and project MI are the same app-only flow — the token is the **agent's own** identity
vs. the **shared project** identity. Pick project MI when all agents in the project should share one
access level.

#### B. Catalog MCP server (catalog decides)

For a **Foundry Tool Catalog** server the auth mode is **predetermined by the catalog API** — the
portal just shows it and you complete the credential/consent step. Both catalog schemes act **as the
calling user** and store **no user-supplied secret**; they differ in the token.

| Scheme | `authType` | Token | Example catalog servers | Page |
|--------|-----------|-------|-------------------------|------|
| **Managed OAuth** | `OAuth2` (Foundry-owned connector) | Foundry-owned OAuth app; first use triggers consent via the APIM broker (MCP `-32006`). | GitHub, other non-Microsoft connectors. | [mcp-oauth-managed.md](tools/mcp-oauth-managed.md) |
| **1P OBO** (Microsoft first-party on-behalf-of) | `UserEntraToken` | native Entra token minted for the user, scoped to the server's `audience`. Microsoft-first-party only. | Foundry MCP (`mcp.ai.azure.com`), Work IQ, Fabric IQ. | [mcp-1p-obo.md](tools/mcp-1p-obo.md) |

The example lists are illustrative — which servers fall in each is fixed by the catalog API, so the
**catalog UI is authoritative**.

> **Same server, two paths.** Work IQ appears in the catalog as **1P OBO** (`UserEntraToken`), but
> you can also attach it as **your own** server via OAuth-custom (`OAuth2`) with your own app
> registration ([mcp-oauth-custom.md](tools/mcp-oauth-custom.md)). Ownership, not the server, decides
> which section applies.

> Combining several tools in one toolbox? See [multi-tool.md](tools/multi-tool.md) and the
> [composition rule](#composition-rule-multiple-tools-in-one-toolbox) below.

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
