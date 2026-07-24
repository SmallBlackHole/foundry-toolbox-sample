# Built-in Tools

Foundry provides a set of **built-in** tools you add to a toolbox from the **Configured** tab — no
custom endpoint to register. Some are fully connectionless; others reference an existing resource
(a vector store, an Azure AI Search index, a Bing Custom Search instance, or a Playwright workspace).

| Tool | `type` | Connection / resource | Notes |
|------|--------|-----------------------|-------|
| **Web search** (basic Bing) | `web_search` | none | Public web results via Grounding with Bing Search. |
| **Bing Custom Search** | `web_search` + `custom_search_configuration` | `GroundingWithCustomSearch` connection (`ApiKey`) | Web search scoped to specific domains. |
| **Code interpreter** | `code_interpreter` | none | Runs sandboxed Python; optionally attach files. |
| **File search** | `file_search` | a **vector store** in the same project (by ID) | Retrieval over uploaded files. |
| **Azure AI Search** | `azure_ai_search` | `CognitiveSearch` connection (`ApiKey`) + index | Query an existing AI Search index. |
| **Browser automation** | `browser_automation_preview` | `PlaywrightWorkspace` connection (project MI) | Drive a real browser (navigate, click, extract). |

The **flow is the same for every built-in tool** — create a toolbox, add the tool from the
**Configured** tab (supplying its resource where required), then publish and copy the endpoint. The
VS Code and Portal sections below show that shared flow once; the [CLI](#cli-azd) section has a
subsection per tool with its connection setup and toolbox YAML.

---

## VS Code (Foundry Toolkit)

1. In the **Foundry Toolkit** view (signed in), open **Tool Catalog** → **Catalog** tab → **Toolboxes** → **Create Your Toolbox**.

   ![VS Code — Tool Catalog, Create Your Toolbox](../images/vsc-toolcatalog.png)
2. Enter a toolbox **Name** and description, then in the **Included** panel click **+ Add ▾** → **Add tools**.
3. In the **Select a tool** dialog, stay on the **Configured** tab and select the tool.
4. Back on **Build a Custom Toolbox**, click **Publish**. The toolbox appears on the **Toolboxes** tab. Use the copy icon in the **Endpoint URL** column to copy the consumer MCP endpoint into your agent's `TOOLBOX_ENDPOINT`.

## Portal (Foundry / Azure)

1. In the [Foundry portal](https://ai.azure.com/), open **Tools** → **Toolboxes** tab → **Create toolbox**.
2. Under **Included**, click **+ Add** → **Add tool** to open the **Select a tool** dialog.
3. On the **Configured** tab, select the tool, supply its resource/connection if required then click **Add tool**.
4. Click **Publish**, then copy the consumer MCP endpoint into your agent's `TOOLBOX_ENDPOINT`.


## CLI (`azd`)

Each tool is one entry under `tools:`. There are two methods to define the toolbox — use either:

- **Method A — `toolbox.yaml`**: a standalone file created with `azd ai toolbox create`.
- **Method B — `azure.yaml`**: declared alongside the agent and deployed with `azd deploy`.

Both use the same tool entry. Combine multiple tools by listing several entries under `tools:`. Each
subsection below shows, for one tool, the connection to create first (if any) and both methods.

### Web search (basic Bing)

Connectionless. To **scope** search to specific domains, use [Bing Custom Search](#bing-custom-search)
instead.

**Method A — `toolbox.yaml`:**

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

**Method B — `azure.yaml`:**

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

Docs: [Web Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-search) ·
[Web Search vs Grounding with Bing Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-overview)

### Bing Custom Search

Like web search but **scoped to specific domains** via a Bing Custom Search instance. Needs a Bing
Custom Search instance + Bing account resource ID
([setup](https://learn.microsoft.com/azure/ai-foundry/agents/how-to/tools/bing-custom-search)) and a
`GroundingWithCustomSearch` connection.

```bash
azd ai connection create bingcustomconn \
  --kind grounding-with-custom-search \
  --target https://api.bing.microsoft.com/ \
  --auth-type api-key \
  --api-key "<bing_api_key>" \
  --metadata "ResourceId=<bing_resource_id>" \
  --metadata "type=bing_custom_search_preview" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method A — `toolbox.yaml`:**

```yaml
# toolbox.yaml
description: bing-custom-search toolbox
tools:
  - type: web_search
    name: web_search
    custom_search_configuration:
      instance_name: "<bing_custom_instance>"
      project_connection_id: bingcustomconn
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method B — `azure.yaml`:**

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: web_search
        name: web_search
        custom_search_configuration:
          instance_name: "<bing_custom_instance>"
          project_connection_id: bingcustomconn
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

Docs: [Grounding with Bing Custom Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-overview)

### Code interpreter

Connectionless. In the portal's **Upload files** dialog you can optionally attach files for it to
process.

**Method A — `toolbox.yaml`:**

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

**Method B — `azure.yaml`:**

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

Docs: [Code Interpreter](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/code-interpreter)

### File search

Needs an existing **vector store** (e.g. `vs_xxxxxxxxxxxx`) in the **same project**, with at least one
indexed file. Create one via **Data → Vector stores** in the portal.

**Method A — `toolbox.yaml`:**

```yaml
# toolbox.yaml
description: file-search toolbox
tools:
  - type: file_search
    name: file_search
    vector_store_ids:
      - "vs_xxxxxxxxxxxx"     # flat: sibling of type, NOT nested under file_search
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method B — `azure.yaml`:**

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: file_search
        name: file_search
        vector_store_ids:
          - "vs_xxxxxxxxxxxx"
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

- `vector_store_ids` is a **flat** sibling of `type` — do **not** nest it under a `file_search:` object.
- When calling the tool over MCP, the argument is `queries` (an **array** of strings), e.g.
  `{"queries": ["what is the refund policy?"]}`.

Docs: [File Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/file-search)

### Azure AI Search

Needs an existing **Azure AI Search service + index**
([create one](https://learn.microsoft.com/azure/search/search-create-service-portal)) and a
`CognitiveSearch` connection.

```bash
azd ai connection create aisearchconn \
  --kind cognitive-search \
  --target "https://<my-search>.search.windows.net/" \
  --auth-type api-key \
  --api-key "<ai_search_admin_key>" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method A — `toolbox.yaml`:**

```yaml
# toolbox.yaml
description: ai-search toolbox
tools:
  - type: azure_ai_search
    name: azure_ai_search
    index_name: "<your_index_name>"
    project_connection_id: aisearchconn
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method B — `azure.yaml`:**

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: azure_ai_search
        name: azure_ai_search
        index_name: "<your_index_name>"
        project_connection_id: aisearchconn
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

- For multiple indexes, add one `azure_ai_search` entry per index (each needs a unique `name`).

Docs: [Azure AI Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/azure-ai-search)

### Browser automation

Drive a real browser via an **Azure Playwright workspace**
([create one](https://aka.ms/pww/docs/manage-workspaces)). Uses a `PlaywrightWorkspace` connection
with project managed identity. `browser_automation_preview` is a preview tool type.

```bash
azd ai connection create browserautomation \
  --kind playwright-workspace \
  --target "<playwright_service_url>" \
  --auth-type project-managed-identity \
  --metadata "resourceId=<playwright_service_resource_id>" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method A — `toolbox.yaml`:**

```yaml
# toolbox.yaml
description: browser-automation toolbox
tools:
  - type: browser_automation_preview
    name: browser_automation
    browser_automation_preview:
      connection:
        project_connection_id: browserautomation
    require_approval: "never"
```

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Method B — `azure.yaml`:**

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: browser_automation_preview
        name: browser_automation
        browser_automation_preview:
          connection:
            project_connection_id: browserautomation
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

Docs: [Browser automation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/browser-automation)
