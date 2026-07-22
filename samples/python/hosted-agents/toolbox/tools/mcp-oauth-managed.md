# 6. MCP — OAuth (managed connector)

Connect to an MCP server via OAuth2 where **Foundry manages the app registration** — you supply no
client ID or secret. The first tool invocation returns a **consent URL** (MCP error code `-32006`);
open it, consent, and retry.

**Connection required?** Yes (`OAuth2`, managed connector). **Example server:**
`https://api.githubcopilot.com/mcp` (connector `foundrygithubmcp`).

---

## 1. Create the connection

```bash
azd ai connection create ghmcpoauth \
  --kind remote-tool \
  --target https://api.githubcopilot.com/mcp \
  --auth-type oauth2 \
  --connector-name foundrygithubmcp \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

## 2a. CLI — Way A (`toolbox.yaml`)

```yaml
# toolbox.yaml
description: github-mcp-oauth toolbox
tools:
  - type: mcp
    server_label: github
    project_connection_id: ghmcpoauth
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
        server_label: github
        project_connection_id: ghmcpoauth
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
   endpoint** (e.g. `https://api.githubcopilot.com/mcp`), and set **Authentication** to **OAuth
   Identity Passthrough**. Click **Connect**.
4. Click **Publish** and copy the endpoint into `TOOLBOX_ENDPOINT`. The **first** agent invocation
   triggers OAuth consent (MCP code `-32006`).

> **Managed vs. custom OAuth in the portal.** The Custom-tab MCP dialog's **OAuth Identity
> Passthrough** option is the *bring-your-own-app* path — it collects Client ID / secret / Auth URL /
> Token URL / Scopes (see [MCP OAuth custom app](mcp-oauth-custom.md)). For a **managed** connector
> where Foundry owns the OAuth app and you supply no client credentials, add the server from the
> **Catalog** tab instead (e.g. **GitHub**) — see [MCP key auth](mcp-key-auth.md) for the Catalog
> flow. The managed-connector CLI form (`--connector-name`) shown above has no dedicated Custom-tab
> equivalent.

![Foundry portal — Add MCP tool (Authentication options)](../images/portal-mcp-oauth-managed.png)

## VS Code (Foundry Toolkit)

1. Open the **Microsoft Foundry** view and sign in.
2. **Connections** → **Create connection** → **MCP OAuth (managed)** → select connector.
3. **Tools** → **Toolboxes** → **Create toolbox** → add MCP server → select the connection.

![VS Code Foundry Toolkit — MCP OAuth managed (TODO: screenshot)](../images/vscode-mcp-oauth-managed.png)

---

## Notes

- The **first** invocation triggers OAuth consent — the tool call returns MCP code `-32006` with a
  consent URL. Complete consent, then retry.

## References

- [MCP tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
