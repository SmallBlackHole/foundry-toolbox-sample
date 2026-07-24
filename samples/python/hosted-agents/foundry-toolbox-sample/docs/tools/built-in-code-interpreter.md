# 3. Code Interpreter

Executes Python code in a secure, sandboxed environment and returns the output. Useful for
calculations, data manipulation, and chart generation. Connectionless built-in — no secrets.

---

## VS Code (Foundry Toolkit)

1. In the **Foundry Toolkit** view (signed in), open **Tool Catalog** → **Catalog** tab → **Toolboxes** → **Create Your Toolbox**.

   ![VS Code — Tool Catalog, Create Your Toolbox](../images/vsc-toolcatalog.png)
2. Enter a toolbox **Name** and description, then in the **Included** panel click **+ Add ▾** → **Add tools**.

   ![VS Code — Build a Custom Toolbox, Add tools](../images/vsc-toolbox-create.png)

3. In the **Select a tool** dialog, stay on the **Configured** tab. Select the **Code Interpreter** card (no connection needed) then click **Add Tools**.

   ![VS Code — Select a tool, Configured tab](../images/vsc-toolbox-tool-catalog-build-in.png)

4. Back on **Build a Custom Toolbox**, click **Publish**. The toolbox appears on the **Toolboxes**
   tab. Use the copy icon in the **Endpoint URL** column to copy the consumer MCP endpoint into your
   agent's `TOOLBOX_ENDPOINT` — or click **Scaffold code template** to generate a hosted agent
   wired to it.

   ![VS Code — Toolboxes list, copy endpoint URL](../images/vsc-copy-endpoint.png)

---

## CLI — Way A (`toolbox.yaml`)

```yaml
# toolbox.yaml
description: code-interpreter toolbox
tools:
  - type: code_interpreter
    name: code_interpreter
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
      - type: code_interpreter
        name: code_interpreter
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

3. On the **Configured** tab, select **Code interpreter** (no connection needed). In the **Upload files** dialog, optionally attach files for it to process, then click **Attach**.

4. Click **Publish**, then copy the consumer MCP endpoint into your agent's `TOOLBOX_ENDPOINT`.

   ![Foundry portal — published toolbox (endpoint)](../images/portal-web-search-detail.png)

---

## References

- [Code Interpreter tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/code-interpreter)
