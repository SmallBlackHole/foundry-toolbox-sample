# 1. Web Search (basic Bing)

Grounds agent responses in real-time public web results via Grounding with Bing Search. This is a
**connectionless built-in** — the simplest toolbox scenario. No connection or secrets required.

---

## VS Code (Foundry Toolkit)

1. In the **Foundry Toolkit** view (signed in), open **Tool Catalog** → **Catalog** tab → **Toolboxes** → **Create Your Toolbox**.

   ![VS Code — Tool Catalog, Create Your Toolbox](../images/vsc-toolcatalog.png)
2. Enter a toolbox **Name** and description, then in the **Included** panel click **+ Add ▾** → **Add tools**.

   ![VS Code — Build a Custom Toolbox, Add tools](../images/vsc-toolbox-create.png)

3. In the **Select a tool** dialog, stay on the **Configured** tab. Select the **Web search** card then click **Add Tools**.

   ![VS Code — Select a tool, Configured tab (Web search)](../images/vsc-toolbox-tool-catalog-build-in.png)

4. Back on **Build a Custom Toolbox**, click **Publish**. The toolbox appears on the **Toolboxes**
   tab. Use the copy icon in the **Endpoint URL** column to copy the consumer MCP endpoint into your
   agent's `TOOLBOX_ENDPOINT` — or click **Scaffold code template** to generate a hosted agent
   wired to it.

   ![VS Code — Toolboxes list, copy endpoint URL](../images/vsc-copy-endpoint.png)

---

## CLI — Way A (`toolbox.yaml`)

```yaml
# toolbox.yaml
description: web-search toolbox
tools:
  - type: web_search
    name: web_search
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

## CLI — Way B (`azure.yaml`)

Declare the toolbox as a service alongside the agent; `azd deploy` upserts it.

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: web_search
        name: web_search
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

1. In the [Foundry portal](https://ai.azure.com/) (your project selected), open **Tools** → **Toolboxes** tab → **Create toolbox**. Give it a **Name**.
2. Under **Included**, click **+ Add** → **Add tool** to open the **Select a tool** dialog.

3. On the **Configured** tab, select **Web search** (Grounding with Bing Search — no connection needed) then click **Add tool**.

   ![Foundry portal — Add the Web Search Tool dialog](../images/portal-web-search.png)

4. Click **Publish**, then copy the consumer MCP endpoint into your agent's `TOOLBOX_ENDPOINT`.

   ![Foundry portal — published toolbox (endpoint)](../images/portal-web-search-detail.png)

---

## Notes

- Basic Bing needs no connection. To **scope** search to specific domains, use
  [Bing Custom Search](built-in-bing-custom-search.md) instead (which does need a connection).

## References

- [Web Search tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-search)
- [Web Search vs Grounding with Bing Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-overview)
