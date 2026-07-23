# Foundry Toolbox — User Guide

A **toolbox** is a managed Microsoft Foundry resource: you define a curated set of tools once and
expose them through a **single MCP-compatible endpoint**. Foundry handles credential injection,
token refresh, OAuth consent, and enterprise policy at runtime. The recommended way to give a
**hosted agent** its tools is to connect it to a toolbox through this one endpoint — so you can add,
remove, or reconfigure tools **without changing agent code**. 

---

## Prerequisites

1. **RBAC** — the calling identity (you as developer, and the agent's identity at runtime) needs
   **Foundry User** on the Foundry project. Grant it at project scope if missing. 
2. **A surface to author on** — install whichever you'll use:
   - **CLI** — the unified Foundry extension bundle:
     ```bash
     azd ext install microsoft.foundry
     azd auth login
     ```
   - **VS Code** — the [Microsoft Foundry](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-ai-foundry)
     extension (Foundry Toolkit).

---

## Tool types

Every tool in a toolbox is one of **four types**. This table covers what each is and links to each
tool's page. MCP is the only type with multiple auth modes — those are detailed in
[MCP authentication](#mcp-authentication) below.

| Tool | Page |
|------|------|
| **Built-in** — Web search (basic Bing) | [web-search.md](tools/web-search.md) |
| **Built-in** — Code interpreter | [code-interpreter.md](tools/code-interpreter.md) |
| **Built-in** — File search (vector store) | [file-search.md](tools/file-search.md) |
| **Built-in** — Azure AI Search | [azure-ai-search.md](tools/azure-ai-search.md) |
| **Built-in** — Bing Custom Search | [bing-custom-search.md](tools/bing-custom-search.md) |
| **Built-in** — Browser automation | [browser-automation.md](tools/browser-automation.md) |
| **MCP connection** — Remote MCP server (your own or catalog) | [MCP authentication](#mcp-authentication) |
| **A2A connection** — Remote agent (Agent-to-Agent) | [a2a.md](tools/a2a.md) |
| **OpenAPI connection** — External REST API (OpenAPI 3.x spec) | [openapi.md](tools/openapi.md) |

### MCP authentication

**Group A** modes work for **any** MCP server. **Group B** adds two more that **only** some catalog servers can use.

#### A. Any MCP server (you configure the auth)

Bring any remote MCP endpoint and pick the mode that matches what your MCP server expects.

| Mode | Description | Page |
|------|-------------|------|
| **No auth** | Anonymous — you provide nothing. | [mcp-noauth.md](tools/mcp-noauth.md) |
| **Key auth** | A shared static key you provide as a header (e.g. `Authorization: Bearer <token>`). | [mcp-key-auth.md](tools/mcp-key-auth.md) |
| **OAuth** | Use when the MCP server needs to know **who the user is** — the call runs as the signed-in user. | [mcp-oauth-custom.md](tools/mcp-oauth-custom.md) |
| **Agent identity** | Use when the MCP server **doesn't need to know the user** — the call runs as the agent itself (or the shared project identity). | [mcp-agent-identity.md](tools/mcp-agent-identity.md) |


#### B. Foundry Tool Catalog servers (Foundry pre-wires the auth)

Some catalog servers offer two extra modes — Foundry has pre-registered the OAuth app or OBO broker,
so you don't create your own Entra app or config agent identity.

| Scheme | Description | Example MCP server | Page |
|--------|-------------|--------------------|------|
| **Managed OAuth** | You don't create your own Entra app. The first time you use this MCP, you sign in and consent once. | Some MCPs Microsoft has pre-integrated, e.g. GitHub, Vercel. | [mcp-oauth-managed.md](tools/mcp-oauth-managed.md) |
| **1P OBO** (Microsoft first-party on-behalf-of) | You don't create your own Entra app, and no sign-in or consent is needed — Foundry passes your identity through automatically. Microsoft-first-party only. | Only certain Microsoft first-party MCPs, e.g. Foundry MCP, Work IQ. | [mcp-1p-obo.md](tools/mcp-1p-obo.md) |

The example lists are illustrative — each catalog server's actual auth mode is shown in the Foundry
Tool Catalog, viewable in both the **VS Code Foundry Toolkit extension** and the **Foundry portal**.

---

## Versions & endpoints

Every change to a toolbox produces a new **immutable version**. A toolbox has a **default version**,
which the consumer endpoint serves. The first version is auto-promoted; promote later ones with
`azd ai toolbox publish <name> <version>`.

| Role | Endpoint | Use |
|------|----------|-----|
| **Consumer** | `{project_endpoint}/toolboxes/{toolbox_name}/mcp?api-version=v1` | Connect agents. Always serves the default version. |
| **Developer** | `{project_endpoint}/toolboxes/{toolbox_name}/versions/{version}/mcp?api-version=v1` | Test a specific version before promoting. |

`?api-version=v1` is **required** (otherwise HTTP 400). Auth: bearer token with scope
`https://ai.azure.com/.default`. Connect agents to the **consumer** endpoint so promoting a new
version needs no redeploy.

## References

- [Toolbox (how-to)](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/toolbox)
- [Tool Catalog](https://learn.microsoft.com/azure/foundry/agents/concepts/tool-catalog)
- [Foundry Toolkit (VS Code)](https://code.visualstudio.com/docs/intelligentapps/tool-catalog)
- [Foundry portal](https://ai.azure.com/)
