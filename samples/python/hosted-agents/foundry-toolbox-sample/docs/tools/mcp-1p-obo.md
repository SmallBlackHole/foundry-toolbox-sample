# 9. MCP — 1P OBO (Microsoft first-party on-behalf-of)

Connect to a **Microsoft first-party** MCP server that accepts the **calling user's Entra token**.
Foundry passes the caller's identity through to the downstream server on-behalf-of (OBO) — the tool
acts as the user, not as the agent. Useful for per-user data access (mail, files) where the server
enforces the user's own permissions. This is a **catalog** auth mode: which servers support it is
fixed by the catalog, not something you configure.

**Connection required?** Yes (`UserEntraToken`). **Example server:** the
[Microsoft Foundry MCP server](https://learn.microsoft.com/azure/foundry/mcp/get-started)
(`https://mcp.ai.azure.com`).

> **1P OBO vs. managed/custom OAuth vs. agent identity?** See
> [MCP authentication modes compared](../README.md#mcp-authentication) in the toolbox
> guide for how all the auth types differ and when to use each.

---

## Finding the audience

A 1P OBO connection needs an **audience** — the Entra resource the server validates
tokens against. Read it from the server's OAuth metadata:

```bash
curl https://mcp.ai.azure.com/.well-known/oauth-protected-resource
```

Use the `resource` value (e.g. `https://mcp.ai.azure.com`) as the audience.

## 1. Create the connection

```bash
azd ai connection create foundrymcpconn \
  --kind remote-tool \
  --target https://mcp.ai.azure.com \
  --auth-type user-entra-token \
  --audience https://mcp.ai.azure.com \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

## 2a. CLI — Way A (`toolbox.yaml`)

```yaml
# toolbox.yaml
description: 1p-obo-mcp toolbox
tools:
  - type: mcp
    server_label: foundry-mcp
    project_connection_id: foundrymcpconn
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

## 2b. CLI — Way B (`azure.yaml`)

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: mcp
        server_label: foundry-mcp
        project_connection_id: foundrymcpconn
  my-agent:
    host: azure.ai.agent
    uses:
      - agent-tools
    environmentVariables:
      - name: TOOLBOX_NAME
        value: agent-tools
```

```bash
azd deploy agent-tools
```

---

## Portal (Foundry / Azure)

1. In the [Foundry portal](https://ai.azure.com/), open **Tools** → **Toolboxes** tab →
   **Create toolbox**. Give it a **Name**.
2. Under **Included**, click **+ Add** → **Add tool** → the **Custom** tab → **Model Context
   Protocol (MCP)** → **Create**.
3. In the **Add Model Context Protocol tool** dialog: enter a **Name**, set the **Remote MCP Server
   endpoint** (e.g. `https://mcp.ai.azure.com`), and set **Authentication** to **OAuth Identity
   Passthrough** — Foundry forwards the calling user's Entra token. Click **Connect**.
4. Click **Publish** and copy the endpoint into `TOOLBOX_ENDPOINT`.

![Foundry portal — Add MCP tool (Authentication options)](../images/portal-mcp-entra-passthrough.png)

## VS Code (Foundry Toolkit)

1. Open the **Microsoft Foundry** view and sign in.
2. **Connections** → **Create connection** → **MCP (1P OBO)** → set target + audience.
3. **Tools** → **Toolboxes** → **Create toolbox** → add MCP server → select the connection.

![VS Code Foundry Toolkit — MCP Entra passthrough (TODO: screenshot)](../images/vscode-mcp-entra-passthrough.png)

---

## Notes

- The tool runs as the **calling user** — the downstream server enforces that user's permissions.
- For connector-backed servers (e.g. Microsoft 365 / Outlook Mail), find the audience in the
  Foundry Tools Catalog rather than the `.well-known` endpoint.

## References

- [MCP tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
- [Microsoft Foundry MCP server](https://learn.microsoft.com/azure/foundry/mcp/get-started)
