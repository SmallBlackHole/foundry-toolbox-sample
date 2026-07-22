# Troubleshooting

## A single failing MCP source can fail the whole agent

A toolbox aggregates every tool source behind one MCP endpoint. If **any** referenced MCP server fails while the toolbox enumerates tools (`tools/list`), the toolbox fails the entire enumeration, so the agent can't load its tools and every request returns an error (HTTP 500) until that source recovers.

For example, a flaky third-party MCP source can intermittently return `HTTP 502 (Bad Gateway)` during enumeration, which surfaces as:

```
tools/list failed for 1 tool source(s), succeeded for 5 tool source(s)
{"errors":[{"name":"<server_label>","type":"mcp","error":{"code":"HTTP_502", ...}}]}
```

This is an upstream/service hiccup, not a problem with the agent code. Mitigations:

- Retry the request — these failures are usually transient.
- If a source is persistently unavailable, temporarily remove its tool entry (and connection) from `toolbox.yaml`, recreate the toolbox, and update `TOOLBOX_ENDPOINT`.
- Inspect deployed agent logs with `azd ai agent monitor` to identify which source failed.

## Entra pass-through forwards the caller's identity

The Foundry MCP tool authenticates with **Entra pass-through** (`foundrymcpconn`): Foundry forwards the
calling user's Entra token to `https://mcp.ai.azure.com`. The token is forwarded both from the Foundry
portal **Agent Playground** (signed-in user) and by `azd ai agent invoke` (the developer's Entra token),
so the tools operate as that user and only act on resources the user can already access. The Foundry MCP
server requires no extra license — just access to the Foundry project.

Because the tool acts as a specific user, running the agent **locally** (`python main.py`) or calling the
endpoint with a raw token uses whatever identity that token represents (`az login` user locally, the
agent's managed identity when hosted). If that identity has no access to the target resources, the tool
returns an authorization error even though it is discovered and called correctly.

> Some other Entra pass-through MCP servers add their **own** entitlement checks on top of the token. For
> example, the Microsoft 365 / WorkIQ servers (Outlook Mail, Teams) require the caller to hold a
> **Microsoft 365 Copilot (Business Chat)** license; without it they fail with
> `WorkIQ license check failed. Required service plan(s): [M365_COPILOT_BUSINESS_CHAT]`. That is a
> property of those servers, not of Entra pass-through itself.
