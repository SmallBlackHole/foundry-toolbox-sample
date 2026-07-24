# 4. MCP — Unauthenticated (public server)

Connect the agent to a **public MCP server** that requires no authentication. Foundry proxies the
server URL; no credentials are stored, and no connection resource is needed — the server URL is given
inline on the tool.

**Example server:** `https://learn.microsoft.com/api/mcp` (the
[Microsoft Learn MCP server](https://learn.microsoft.com/training/support/mcp), which exposes
Microsoft documentation search, doc fetch, and code-sample search).

---

## VS Code (Foundry Toolkit)

Follow the shared [Create the toolbox](../../README.md#create-the-toolbox) flow in the README (create
the toolbox → **+ Add ▾** → **Add tools** → publish → copy the endpoint). In the **Select a tool**
dialog, this tool's config is:

1. Switch to the **Custom** tab and select **Model Context Protocol (MCP)**.

   ![VS Code — Select a tool, Custom tab](../images/vsc-custom-tool.png)

   > To browse pre-listed remote MCP servers instead of pasting a URL, use the **Catalog** tab.

2. In the **Add Model Context Protocol tool** dialog, enter a **Connection Name**, the **Remote MCP
   Server Endpoint** (e.g. `https://learn.microsoft.com/api/mcp`), and set **Authentication** to
   **Unauthenticated**. Click **Connect**.

   ![VS Code — Add Model Context Protocol tool dialog (Authentication: Unauthenticated)](../images/vsc-mcp-noauth-config-dialog.png)

---

## CLI — Way A (`toolbox.yaml`)

```yaml
# toolbox.yaml
description: public-mcp toolbox
tools:
  - type: mcp
    server_label: learn_mcp
    server_url: "https://learn.microsoft.com/api/mcp"
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

## CLI — Way B (`azure.yaml`)

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: mcp
        server_label: learn_mcp
        server_url: "https://learn.microsoft.com/api/mcp"
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


## References

- [MCP tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
