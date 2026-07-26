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

> This page covers only the **built-in tool** parts — the Configured-tab selection and any
> resource/connection each tool needs. For the shared toolbox flow (create → publish → copy the
> endpoint), see the [README](../../README.md#create-the-toolbox).

## Create the tool connection & toolbox

### Foundry Toolkit in VS Code

1. Follow the README's [Create the toolbox](../../README.md#create-the-toolbox) steps to open the **Select a tool** dialog.
2. Stay on the **Configured** tab and select the tool, then follow the config dialog — it prompts for any resource or connection the tool needs (and lets you create one inline). Click **Add tool**.

### `azd` CLI

Each tool is one entry under `tools:`. Create the connection it needs first (if any), then add the
tool to a toolbox one of two ways:

- **Way A — standalone toolbox** (`toolbox.yaml` + `azd ai toolbox create`): builds the toolbox on
  its own. Best for testing, or when the toolbox is shared across agents.
- **Way B — toolbox in an agent project** (`azure.yaml` + `azd deploy`): declares the toolbox next to
  your agent and ships them together. Best when the toolbox belongs to one agent project.

Combine multiple tools by listing several entries under `tools:`. Each subsection below shows one
tool's connection (if any) and both ways.

#### Web search (basic Bing)

Connectionless. To **scope** search to specific domains, use [Bing Custom Search](#bing-custom-search)
instead.

**Way A — standalone toolbox (`toolbox.yaml`)**

1. Write `toolbox.yaml`:

   ```yaml
   # toolbox.yaml
   description: web-search toolbox
   tools:
     - type: web_search
       name: web_search
       require_approval: "never"
   ```

2. Create the toolbox:

   ```bash
   azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
   ```

3. Copy the versioned MCP endpoint it prints into your agent's `TOOLBOX_ENDPOINT`.

**Way B — toolbox in an agent project (`azure.yaml`)**

1. Declare the toolbox and agent together in `azure.yaml`:

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

2. Deploy the toolbox (and agent) — no `TOOLBOX_ENDPOINT` needed, the agent resolves it from `TOOLBOX_NAME`:

   ```bash
   azd deploy agent-tools
   ```

Docs: [Web Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-search) ·
[Web Search vs Grounding with Bing Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-overview)

#### Bing Custom Search

Like web search but **scoped to specific domains** via a Bing Custom Search instance. Needs a Bing
Custom Search instance + Bing account resource ID
([setup](https://learn.microsoft.com/azure/ai-foundry/agents/how-to/tools/bing-custom-search)) and a
`GroundingWithCustomSearch` connection.

Create the connection first (both ways):

```bash
azd ai connection create bingcustomconn \
  --kind grounding-with-custom-search \
  --target https://api.bing.microsoft.com/ \
  --auth-type api-key \
  --key "<bing_api_key>" \
  --metadata "ResourceId=<bing_resource_id>" \
  --metadata "type=bing_custom_search_preview" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Way A — standalone toolbox (`toolbox.yaml`)**

1. Write `toolbox.yaml` referencing the connection by name:

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

2. Create the toolbox:

   ```bash
   azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
   ```

3. Copy the versioned MCP endpoint it prints into your agent's `TOOLBOX_ENDPOINT`.

**Way B — toolbox in an agent project (`azure.yaml`)**

1. Declare the toolbox and agent together in `azure.yaml`:

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

2. Deploy the toolbox (and agent) — no `TOOLBOX_ENDPOINT` needed, the agent resolves it from `TOOLBOX_NAME`:

   ```bash
   azd deploy agent-tools
   ```

Docs: [Grounding with Bing Custom Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/web-overview)

#### Code interpreter

Connectionless. In the portal's **Upload files** dialog you can optionally attach files for it to
process.

**Way A — standalone toolbox (`toolbox.yaml`)**

1. Write `toolbox.yaml`:

   ```yaml
   # toolbox.yaml
   description: code-interpreter toolbox
   tools:
     - type: code_interpreter
       name: code_interpreter
       require_approval: "never"
   ```

2. Create the toolbox:

   ```bash
   azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
   ```

3. Copy the versioned MCP endpoint it prints into your agent's `TOOLBOX_ENDPOINT`.

**Way B — toolbox in an agent project (`azure.yaml`)**

1. Declare the toolbox and agent together in `azure.yaml`:

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

2. Deploy the toolbox (and agent) — no `TOOLBOX_ENDPOINT` needed, the agent resolves it from `TOOLBOX_NAME`:

   ```bash
   azd deploy agent-tools
   ```

Docs: [Code Interpreter](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/code-interpreter)

#### File search

Needs an existing **vector store** (e.g. `vs_xxxxxxxxxxxx`) in the **same project**, with at least one
indexed file
([create one](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/file-search#upload-files-and-add-them-to-a-vector-store)) —
in the portal, via **Data → Vector stores**.

**Way A — standalone toolbox (`toolbox.yaml`)**

1. Write `toolbox.yaml` with your vector store ID:

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

2. Create the toolbox:

   ```bash
   azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
   ```

3. Copy the versioned MCP endpoint it prints into your agent's `TOOLBOX_ENDPOINT`.

**Way B — toolbox in an agent project (`azure.yaml`)**

1. Declare the toolbox and agent together in `azure.yaml`:

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

2. Deploy the toolbox (and agent) — no `TOOLBOX_ENDPOINT` needed, the agent resolves it from `TOOLBOX_NAME`:

   ```bash
   azd deploy agent-tools
   ```

- `vector_store_ids` is a **flat** sibling of `type` — do **not** nest it under a `file_search:` object.
- When calling the tool over MCP, the argument is `queries` (an **array** of strings), e.g.
  `{"queries": ["what is the refund policy?"]}`.

Docs: [File Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/file-search)

#### Azure AI Search

Needs an existing **Azure AI Search service + index**
([create one](https://learn.microsoft.com/azure/search/search-create-service-portal)) and a
`CognitiveSearch` connection.

Create the connection first (both ways):

```bash
azd ai connection create aisearchconn \
  --kind cognitive-search \
  --target "https://<my-search>.search.windows.net/" \
  --auth-type api-key \
  --key "<ai_search_admin_key>" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Way A — standalone toolbox (`toolbox.yaml`)**

1. Write `toolbox.yaml` referencing the connection and index:

   ```yaml
   # toolbox.yaml
   description: ai-search toolbox
   tools:
     - type: azure_ai_search
       name: azure_ai_search
       azure_ai_search:
         indexes:
           - project_connection_id: aisearchconn
             index_name: "<your_index_name>"
             query_type: simple      # simple | semantic | vector | vector_simple_hybrid | vector_semantic_hybrid
             top_k: 5
       require_approval: "never"
   ```

2. Create the toolbox:

   ```bash
   azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
   ```

3. Copy the versioned MCP endpoint it prints into your agent's `TOOLBOX_ENDPOINT`.

**Way B — toolbox in an agent project (`azure.yaml`)**

1. Declare the toolbox and agent together in `azure.yaml`:

   ```yaml
   # azure.yaml
   name: my-agent-project
   services:
     agent-tools:
       host: azure.ai.toolbox
       tools:
         - type: azure_ai_search
           name: azure_ai_search
           azure_ai_search:
             indexes:
               - project_connection_id: aisearchconn
                 index_name: "<your_index_name>"
                 query_type: simple
                 top_k: 5
     my-agent:
       host: azure.ai.agent
       uses:
         - agent-tools
       environmentVariables:
         - name: TOOLBOX_NAME
           value: agent-tools
   ```

2. Deploy the toolbox (and agent) — no `TOOLBOX_ENDPOINT` needed, the agent resolves it from `TOOLBOX_NAME`:

   ```bash
   azd deploy agent-tools
   ```

- For multiple indexes, add more entries under `azure_ai_search.indexes:`.
- Index config is **mutually exclusive** per entry: use exactly one of `project_connection_id` +
  `index_name`, `index_connection_id` + `index_name`, or `index_asset_id` alone.

Docs: [Azure AI Search](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/azure-ai-search)

#### Browser automation

Drive a real browser via an **Azure Playwright workspace**
([create one](https://aka.ms/pww/docs/manage-workspaces)). Uses a `PlaywrightWorkspace` connection
with project managed identity. `browser_automation_preview` is a preview tool type.

Create the connection first (both ways):

```bash
azd ai connection create browserautomation \
  --kind playwright-workspace \
  --target "<playwright_service_url>" \
  --auth-type project-managed-identity \
  --metadata "resourceId=<playwright_service_resource_id>" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Way A — standalone toolbox (`toolbox.yaml`)**

1. Write `toolbox.yaml` referencing the connection by name:

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

2. Create the toolbox:

   ```bash
   azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
   ```

3. Copy the versioned MCP endpoint it prints into your agent's `TOOLBOX_ENDPOINT`.

**Way B — toolbox in an agent project (`azure.yaml`)**

1. Declare the toolbox and agent together in `azure.yaml`:

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

2. Deploy the toolbox (and agent) — no `TOOLBOX_ENDPOINT` needed, the agent resolves it from `TOOLBOX_NAME`:

   ```bash
   azd deploy agent-tools
   ```
