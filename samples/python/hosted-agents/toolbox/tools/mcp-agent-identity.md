# 8. MCP — Agent Identity

Connect to an MCP server that accepts **Entra ID tokens issued for the agent's managed identity**
(Agentic Identity). No secrets are stored — Foundry acquires a token for the agent's identity and
presents it to the server. Assign the agent's managed identity an RBAC role on the target server
before deploying.

**Connection required?** Yes (`AgenticIdentity` / project-managed-identity). **Example server:**
Azure Language MCP server.

---

## 1. Create the connection

```bash
azd ai connection create langmcpconn \
  --kind remote-tool \
  --target "https://<language-service>.cognitiveservices.azure.com/language/mcp?api-version=2025-11-15-preview" \
  --auth-type project-managed-identity \
  --audience "https://cognitiveservices.azure.com/" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

> **audience** — the Entra resource the target server validates tokens against.

## 2a. CLI — Way A (`toolbox.yaml`)

```yaml
# toolbox.yaml
description: agent-identity-mcp toolbox
tools:
  - type: mcp
    server_label: language-mcp
    project_connection_id: langmcpconn
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
        server_label: language-mcp
        project_connection_id: langmcpconn
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
   endpoint** (the Azure Language MCP URL), and set **Authentication** to **Microsoft Entra**. A
   **Type** sub-dropdown appears — choose **Agent Identity** (the agent's own managed identity) or
   **Project Managed Identity** — and enter the **Audience** (e.g.
   `https://cognitiveservices.azure.com/`). No secret is required. Click **Connect**.

   ![Foundry portal — Microsoft Entra auth, Type dropdown](../images/portal-mcp-entra-type.png)
4. In the [Azure portal](https://portal.azure.com/), grant the project/agent **managed identity**
   the required RBAC role on the target resource (e.g. **Cognitive Services User**).
5. Click **Publish** and copy the endpoint into `TOOLBOX_ENDPOINT`.

   ![Foundry portal — published Entra MCP toolbox](../images/portal-mcp-agent-identity-detail.png)

## VS Code (Foundry Toolkit)

1. Open the **Microsoft Foundry** view and sign in.
2. **Connections** → **Create connection** → **MCP (agent identity)** → set target + audience.
3. Grant the managed identity RBAC in the Azure portal (step 2 above).
4. **Tools** → **Toolboxes** → **Create toolbox** → add MCP server → select the connection.

![VS Code Foundry Toolkit — MCP agent identity (TODO: screenshot)](../images/vscode-mcp-agent-identity.png)

---

## Notes

- If `tools/list` returns zero for this MCP server, the managed identity likely lacks RBAC on the
  target — verify the role assignment in the Azure portal.

## References

- [MCP tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
- [Azure Language MCP server](https://learn.microsoft.com/azure/ai-services/language-service/concepts/foundry-tools-agents)
