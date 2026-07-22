# Finding the Entra audience for an MCP server

An Entra pass-through connection requires an **audience** — the Entra resource that the MCP server validates tokens against. For the Microsoft Foundry MCP server (`https://mcp.ai.azure.com`), read it from the server's OAuth protected-resource metadata:

```bash
curl https://mcp.ai.azure.com/.well-known/oauth-protected-resource
```

```jsonc
{
  "resource": "https://mcp.ai.azure.com",
  "authorization_servers": ["https://login.microsoftonline.com/common/v2.0"],
  "scopes_supported": ["https://mcp.ai.azure.com/Foundry.Mcp.Tools"]
}
```

Use the `resource` value (`https://mcp.ai.azure.com`) as the audience.

> For connector-backed MCP servers (for example Microsoft 365 / WorkIQ servers such as Outlook Mail), the audience is instead published in the Foundry Tools Catalog. Look it up with the helper scripts in [`scripts/`](../src/agent-framework-agent-with-foundry-toolbox-responses/scripts/): run `./scripts/list-foundry-connectors.ps1 -ConnectorName <name>` (or `./scripts/list-foundry-connectors.sh -n <name>`) and read `AzureActiveDirectoryResourceId` (equivalently `resourceUri`) under `properties.x-ms-connection-parameters`. Run the script with no connector name to list every connector with its name, title, and auth type.
