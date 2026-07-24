# Agent with Foundry Toolbox (Responses Protocol)

An [Agent Framework](https://github.com/microsoft/agent-framework) agent that uses **Foundry Toolbox** for tool discovery, hosted on Microsoft Foundry using the **Responses protocol**. Foundry Toolbox is a managed tool registry in Microsoft Foundry that lets you define tools centrally and share them across agents.

## Tool types

Every tool in a toolbox is one of **four types**: Built-in, MCP, A2A, or OpenAPI. Some types have
multiple auth modes — pick the one that matches how the server expects callers to authenticate.

| Type | Variant | Description | Guide | Actions |
|------|------|-------------|---------------|-------------------|
| **Built-in** | • [Web search](docs/tools/built-in-tools.md)<br>• [Bing custom search](docs/tools/built-in-tools.md)<br>• [Code interpreter](docs/tools/built-in-tools.md)<br>• [File search](docs/tools/built-in-tools.md)<br>• [Azure AI search](docs/tools/built-in-tools.md)<br>• [Browser automation](docs/tools/built-in-tools.md) | Ready-to-use tools hosted by Foundry — no external MCP server to connect. | [Setup guide](docs/tools/built-in-tools.md) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **MCP** | Unauthenticated | Anonymous — you provide nothing. | [Setup guide](docs/tools/mcp-unauthenticated.md) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **MCP** | Key-based | A shared static key you provide as a header (e.g. `Authorization: Bearer <token>`). | [Setup guide](docs/tools/mcp-key-auth.md) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **MCP** | Microsoft Entra<br>(Agent Identity / Project Managed Identity) | • Accesses MCP as the **agent/project** itself.<br>• Need grant the agent/project's identity access on the MCP.<br>• No user sign-in or consent. | [Setup guide](docs/tools/mcp-microsoft-entra.md) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **MCP** | OAuth Identity Passthrough | • Accesses MCP as the signed-in **user**.<br>• Need register the OAuth app.<br>• User consents on first use. | [Setup guide](docs/tools/mcp-oauth-custom.md) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **MCP - Foundry Catalog** | OAuth Identity Passthrough<br>(Managed) | • Accesses MCP as the signed-in **user**.<br>• No OAuth app to set up — Foundry uses its own.<br>• User consents on first use.<br>• Only some catalog MCP support it. | [Setup guide](docs/tools/mcp-oauth-managed.md) | [[Show Supported MCP]](https://ai.azure.com/)<br>[[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **MCP - Foundry Catalog** | OAuth Identity Passthrough<br>(User Entra Token) | • Accesses MCP as the signed-in **user**.<br>• No OAuth app to set up — Foundry uses its own.<br>• No user consent needed.<br>• Only some catalog MCP support it. | [Setup guide](docs/tools/mcp-user-entra-token.md) | [[Show Supported MCP]](https://ai.azure.com/)<br>[[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **OpenAPI** | External REST API | Any REST API with an OpenAPI 3.x spec. | [Setup guide](docs/tools/openapi.md) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |
| **A2A** | Remote agent (Agent-to-Agent) | Call another remote agent. | [A2A sample](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/a2a) | [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools) |

## How it works

### Model Integration

The agent uses `FoundryChatClient` from the Agent Framework to create an OpenAI-compatible Responses client. It connects to the toolbox's MCP endpoint via `FoundryToolbox` — a thin convenience wrapper over `MCPStreamableHTTPTool` that authenticates every request with the credential and forwards the platform per-request call-id — which discovers and invokes the toolbox's tools over MCP at runtime. `FoundryToolbox` resolves the endpoint from the `TOOLBOX_ENDPOINT` environment variable. If that variable isn't set, it builds the endpoint from `FOUNDRY_PROJECT_ENDPOINT` and `TOOLBOX_NAME`.

See [main.py](src/agent-framework-agent-with-foundry-toolbox-responses/main.py) for the full implementation.

## Running the agent

### Option 1: Azure Developer CLI (`azd`)

#### Prerequisites

1. **Azure Developer CLI (`azd`)** — [Install azd](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd) (1.25 or later)
2. Install the unified Foundry CLI extension bundle (provides `azd ai agent`, `connection`, `inspector`, `project`, `routine`, `skill`, and `toolbox`):
   ```bash
   # If you previously installed individual extensions, uninstall them first:
   #   azd ext uninstall azure.ai.agents
   #   azd ext uninstall azure.ai.toolboxes
   azd ext install microsoft.foundry
   ```
3. Authenticate:
   ```bash
   azd auth login
   ```

#### Initialize the agent project

No cloning required. Create a new folder and initialize from the manifest:

```bash
mkdir my-toolbox-agent && cd my-toolbox-agent

azd ai agent init -m https://github.com/microsoft-foundry/foundry-samples/blob/main/samples/python/hosted-agents/agent-framework/responses/04-foundry-toolbox/azure.yaml
```

Follow the prompts to configure your Foundry project and model deployment. If you don't have an existing Foundry project, `azd ai agent init` will guide you through creating one. Initializing also sets the selected project as the active project for the `azd ai` commands that follow.

#### Create the toolbox with `azd ai`

Create the tool connection, create the toolbox, and configure auth by following the
[Tool types](#tool-types) table above — each row links to a detailed page for that tool and auth mode.

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint https://<account>.services.ai.azure.com/api/projects/<project>
```

Once created, `azd ai toolbox create` prints the toolbox's versioned MCP endpoint. Copy that endpoint and store it in your `azd` environment so the agent connects to it:

```bash
azd env set TOOLBOX_ENDPOINT "https://<account>.services.ai.azure.com/api/projects/<project>/toolboxes/agent-tools/versions/1/mcp?api-version=v1"
```

#### Provision Azure resources (if needed)

If you don't already have a Foundry project and model deployment:

```bash
azd provision
```

#### Run the agent locally

```bash
azd ai agent run
```

The agent host will start on `http://localhost:8088`.

#### Invoke the local agent

In a separate terminal, from the project directory:

```bash
azd ai agent invoke --local "What tools do you have?"
```

#### Deploy to Foundry

Once tested locally, deploy to Microsoft Foundry:

```bash
azd deploy
```

For the full deployment guide, see [Deploy a hosted agent](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/deploy-hosted-agent).

#### Invoke the deployed agent

```bash
azd ai agent invoke "What tools do you have?"
```

### Option 2: VS Code (Foundry Toolkit)

#### Prerequisites

1. **VS Code** with the **[Foundry Toolkit](https://marketplace.visualstudio.com/items?itemName=ms-windows-ai-studio.windows-ai-studio)** extension installed.
2. For debugging Python in VS Code, install the **[Python](https://marketplace.visualstudio.com/items?itemName=ms-python.python)** extension pack.

#### Set up the Python virtual environment

- Open the Command Palette (`Ctrl+Shift+P`) and run **Python: Create Environment...** to create a virtual environment in the workspace (or **Python: Select Interpreter** to use an existing one).
- Install dependencies in the virtual environment:
  ```bash
  pip install uv
  uv pip install -r requirements.txt
  ```

#### Create the toolbox

The toolbox must exist in your Foundry project before you run the agent. This sample expects a
toolbox named **`agent-tools`**. Create it with the VS Code Foundry Toolkit extension:

1. In the **Foundry Toolkit** view (signed in), open **Tool Catalog** → **Catalog** tab → **Toolboxes** → **Create Your Toolbox**.

   Or, if you're reading this README in VS Code, directly click [[Create in VS Code]](vscode://ms-windows-ai-studio.windows-ai-studio/open_tools).

   ![VS Code — Tool Catalog, Create Your Toolbox](docs/images/vsc-toolcatalog.png)
2. In the **Included** panel click **+ Add ▾** → **Add tools**. In the **Select a tool** dialog, pick the tool you want and fill in the config dialog.
3. For most tool types, follow the config dialog's flow and default values to complete the setup.

   Only [**OAuth Identity Passthrough**](docs/tools/mcp-oauth-custom.md), [**Microsoft Entra (Agent Identity / Project Managed Identity)**](docs/tools/mcp-microsoft-entra.md), and [**OpenAPI**](docs/tools/openapi.md) require you to provide extra info and complete additional auth setup — follow that tool's detailed page for the exact fields and auth mode.
4. Back on **Build a Custom Toolbox**, click **Publish**. The toolbox appears on the **Toolboxes** tab. Use the copy icon in the **Endpoint URL** column to copy the versioned MCP endpoint into `TOOLBOX_ENDPOINT` in your `.env`:

   ```dotenv
   TOOLBOX_ENDPOINT="https://<account>.services.ai.azure.com/api/projects/<project>/toolboxes/agent-tools/versions/1/mcp?api-version=v1"
   ```

#### Run and debug the agent

Press **F5** to start the agent. The agent starts and the **Agent Inspector** opens automatically. Chat with the agent in the Inspector.

#### Or run manually, then open the Inspector

1. Set the required environment variables and sign in to Azure with the Azure CLI (`az login`).
2. Start the agent: `python main.py` (listens on `http://localhost:8088`).
3. Command Palette (`Ctrl+Shift+P`) → **Foundry Toolkit: Open Agent Inspector**, then send a message to test.

#### Deploy to Foundry

1. Open the Command Palette (`Ctrl+Shift+P`) and run **Foundry Toolkit: Deploy Hosted Agent**. The extension opens a **Deploy Hosted Agent** wizard and reads `agent.yaml` to auto-populate settings.
2. If prompted, complete **Foundry Project Setup** to select subscription and project.
3. On the **Basics** tab, choose deployment method (**Code** or **Container**) and confirm the agent name.
4. On **Review + Deploy**, confirm runtime details, pick **CPU and Memory** size, and click **Deploy**.
5. After deployment, invoke the agent in the Agent Playground and stream live logs from the **Logs** tab.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues and fixes.

## Work with a coding agent

If you use GitHub Copilot for Azure to scaffold a hosted agent that consumes this toolbox, the following skill references describe the same endpoint contract (env var, headers, MCP protocol, citation patterns, and troubleshooting) that the agent must implement:

- [Toolbox reference](https://github.com/microsoft/GitHub-Copilot-for-Azure/blob/main/plugin/skills/microsoft-foundry/foundry-agent/toolbox/toolbox.md) — endpoint format, MCP protocol, OAuth consent handling, citation patterns, and troubleshooting.
- [Use toolbox in a hosted agent](https://github.com/microsoft/GitHub-Copilot-for-Azure/blob/main/plugin/skills/microsoft-foundry/foundry-agent/create/references/use-toolbox-in-hosted-agent.md) — endpoint resolution, env-var contract, payload shape, code integration patterns, and tracing.

## Next steps

- [Quickstart: Create a hosted agent](https://learn.microsoft.com/en-us/azure/foundry/agents/quickstarts/quickstart-hosted-agent) — end-to-end walkthrough using `azd`
- [Tool catalog](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/tool-catalog) — browse available tools to extend your agent (Bing Search, Azure AI Search, file search, code interpreter, and more)
- [Manage hosted agents](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-agent) — monitor and manage deployed agents
- [Basic agent](../01-basic/) — minimal agent with no tools
- [Add local tools](../02-tools/) — sample with locally-defined Python tool functions
- [Build multi-agent workflows](../05-workflows/) — sample with chained agent pipelines
