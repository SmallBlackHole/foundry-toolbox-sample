# Design: Direct MCP with real OBO token exchange (sample 19)

**Date:** 2026-07-09
**Status:** Approved pending review
**Location:** `samples/python/hosted-agents/agent-framework/responses/19-direct-mcp-obo-exchange/`

## Goal

Demonstrate a Foundry **hosted agent** connecting **directly** to a remote MCP
server (no Foundry Toolbox) where the agent performs a genuine Microsoft Entra
**On-Behalf-Of (OBO) token exchange**: it takes the caller's Entra user token,
swaps it — via a confidential client with a client secret — for a
**downstream-scoped** access token, and uses that token to authenticate to the
MCP server.

This is the "customer passes the token, the agent exchanges it" model. The agent
acts *on behalf of* the signed-in user against a downstream resource the user
consented to, not as the agent's own identity.

## Relationship to sibling sample 18

`18-direct-mcp-obo` already exists and is complete. This sample (19) is a
**variant**, not a replacement. The one axis that differs is how the downstream
token is obtained:

| | 18-direct-mcp-obo | 19-direct-mcp-obo-exchange (this) |
| --- | --- | --- |
| Default token | Agent/developer identity (`DefaultAzureCredential`) | OBO-exchanged user token |
| Caller header | Forwarded **verbatim** (pass-through) | Used as the **OBO assertion**, then exchanged |
| Downstream token audience | Same as the caller token | A **different**, downstream-scoped audience |
| Requires app registration + secret | No | **Yes** (confidential client) |
| SDK primitive | `httpx.Auth` + `DefaultAzureCredential` | `httpx.Auth` + `OnBehalfOfCredential` |

Everything else (container-side `MCPStreamableHTTPTool`, the contextvar bridge,
local/remote parity) is intentionally the same shape as 18 so the two read as a
matched pair.

## Why OBO is needed (the real scenario)

A pure pass-through (18, mode 2) only works when the caller already holds a token
whose audience is the MCP server. Real apps often can't do that: the caller
authenticates to *the agent's* API (audience = the agent/app), and the agent must
then obtain a token for a *different* downstream resource (the MCP server) while
preserving the user's identity and consent. That is exactly what the OBO flow is
for — exchange "a token for me" into "a token for the downstream, still as me."

## Architecture

```
Caller
  │  POST /...responses
  │  header: x-client-authorization: Bearer <user_token_for_agent_app>
  ▼
Agent host  (OboExchangeResponsesHostServer — subclass of ResponsesHostServer)
  │  reads context.client_headers["x-client-authorization"]
  │  stores it in a request-scoped ContextVar (_caller_assertion)
  ▼
model decides to call the MCP tool
  ▼
_OboMcpAuth (httpx.Auth on the tool's http client)  — runs on EVERY outbound request
  │  reads _caller_assertion
  │  OnBehalfOfCredential(user_assertion=<user_token>).get_token(<downstream_scope>)
  │  → downstream access token (audience = MCP server)
  │  sets Authorization: Bearer <downstream_token>
  ▼
MCP server  (acts as the user, on the downstream resource)
```

### Components (isolation & responsibility)

1. **`obo.py`** — the OBO exchange, isolated and testable.
   - `build_obo_credential(user_assertion: str) -> OnBehalfOfCredential`
     constructs an `OnBehalfOfCredential` from env config
     (`OBO_TENANT_ID`, `OBO_CLIENT_ID`, `OBO_CLIENT_SECRET`) plus the incoming
     user assertion.
   - One clear job: given a user token, produce a credential that mints
     downstream tokens on that user's behalf. Depends only on `azure.identity`
     and env vars. No knowledge of MCP or the host.

2. **`main.py`** — three pieces, mirroring 18's structure:
   - `_OboMcpAuth(httpx.Auth)` — per-request auth. On each outbound request:
     read the caller assertion from the contextvar; if present, run the OBO
     exchange for `MCP_TOKEN_SCOPE` and set the `Authorization` header. If
     absent, raise a clear error (this sample *requires* a caller token — there
     is no agent-identity fallback, which is the whole point of the OBO story).
   - `OboExchangeResponsesHostServer(ResponsesHostServer)` — overrides
     `_handle_response` to copy `context.client_headers` into the
     `_caller_assertion` contextvar for the lifetime of the response stream,
     then delegates to `super()._handle_response(...)`. (This is the Option-A
     contextvar bridge; it wraps the returned async iterable in a generator that
     sets/resets the contextvar around iteration, so it never touches the
     private streaming/conversion helpers.)
   - Standard `FoundryChatClient` + `Agent` + `MCPStreamableHTTPTool` wiring,
     identical to 18 except the auth class and the server subclass.

3. **Scaffolding** — mirror 18 exactly: `azure.yaml`, `Dockerfile`,
   `.env.example`, `requirements.txt`, `.azdignore`, `.dockerignore`, `README.md`.
   `AGENTS.md`/`CLAUDE.md` are inherited from the responses gallery pattern (18
   does not carry its own; match 18).

### Why `OnBehalfOfCredential` over raw MSAL

`azure.identity.OnBehalfOfCredential` (confirmed present, v1.25.3) wraps MSAL's
`acquire_token_on_behalf_of`, returns a standard `TokenCredential`, caches +
refreshes tokens, and uses the same `azure.identity` import surface every other
sample already uses. It drops straight into the same `httpx.Auth` pattern 18
uses. Raw MSAL would add a second auth library and hand-rolled caching for no
benefit.

## Configuration (`.env.example`)

```
FOUNDRY_PROJECT_ENDPOINT="..."
AZURE_AI_MODEL_DEPLOYMENT_NAME="..."

# Confidential client used for the OBO exchange (app registration + secret).
OBO_TENANT_ID="..."
OBO_CLIENT_ID="..."
OBO_CLIENT_SECRET="..."

# Downstream MCP server and the Entra scope to exchange the user token FOR.
MCP_SERVER_URL="https://mcp.ai.azure.com"
MCP_TOKEN_SCOPE="https://mcp.ai.azure.com/.default"
```

## Local + remote parity

- **Same code both places.** Only the env/config differs.
- **Sending the caller token:** `azd ai agent invoke` has no `--header` flag, so
  the OBO mode is exercised with `curl` (local: `http://localhost:8088`; remote:
  the deployed endpoint). The user token must be a token whose audience the
  confidential client is allowed to exchange (i.e. issued for `OBO_CLIENT_ID`'s
  app, with the downstream permission consented). README documents the exact
  `curl` and how to mint a suitable token for testing.

## Testing & validation

**Can validate in this environment (against 18's venv):**
- `main.py` and `obo.py` import cleanly; the host process starts.
- The contextvar bridge extracts `x-client-authorization` and the value reaches
  `_OboMcpAuth.auth_flow` (verified with a stub/fake assertion, asserting the
  code path and the arguments passed to `OnBehalfOfCredential`).
- Missing-caller-token path raises the intended clear error.

**Cannot fully validate here (requires your Entra tenant):**
- A live OBO exchange returning a real downstream token, and a real MCP call
  succeeding — needs a registered confidential-client app, a secret, the
  downstream API permission + admin consent, and a user token for that app.

The README will state plainly what is proven vs. what needs the caller's Entra
app, rather than implying an end-to-end success that wasn't run.

## Explicitly out of scope (YAGNI)

- No agent-identity fallback (18 covers that; 19 is specifically the OBO story).
- No verbatim pass-through mode (that is 18, mode 2).
- No token caching beyond what `OnBehalfOfCredential` already does.
- No consent-flow UI / incremental consent handling.
