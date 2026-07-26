# OpenAPI

Expose a REST API to the agent from its **OpenAPI 3.x spec**. The spec is embedded **inline** in the
toolbox tool entry. Each operation becomes a tool named `{name}___{operationId}`, so every operation
needs an `operationId`.

---

## Auth modes

The OpenAPI tool supports three authentication types. Pick the one that matches how the target API
authenticates callers.

| Auth type | `auth` object | Connection? | Use when |
|------|---------------|-------------|----------|
| Anonymous | `{ type: anonymous }` | No | Public API, no auth |
| API key / Bearer | `{ type: project_connection, security_scheme: { project_connection_id: <conn> } }` | Yes (`CustomKeys`; key name must match the spec's `securityScheme`) | Non-Microsoft API with a key or Bearer token |
| Managed identity | `{ type: managed_identity, security_scheme: { audience: <resource-uri> } }` | No (authorize the identity on the target) | Target accepts Microsoft Entra ID tokens |

Only **type C** needs the extra Azure step in
[Configure managed-identity authorization](#configure-managed-identity-authorization-azure). Type C
authorizes two different ways depending on the target:

| Target | Audience | Authorize by |
|--------|----------|--------------|
| **RBAC — Azure resource with RBAC** (Storage, AI Search, Key Vault, ARM, …) | the service's well-known resource URI (e.g. `https://search.azure.com`, `https://storage.azure.com`) | granting the Foundry-managed identity an **RBAC role** (Reader or higher) on the resource |
| **App — API behind an Entra app registration** (Azure Functions / App Service Easy Auth, APIM with OAuth, custom Entra-app API) | the app registration's **Application ID URI** (`api://<client-id>`, from **Expose an API**) | **allow-listing** the identity's client ID on the server (*not* RBAC) |

---

## Prerequisites

**1. Prepare the API you want to expose.** Have a REST API reachable by the agent, with an **OpenAPI
3.x spec** that gives every operation an `operationId`. This can be a public API, a third-party API,
or your own service (for example an **Azure Functions** app).

**2. Decide the auth type** — based on how the target API authenticates callers:

- **A — Anonymous:** the API is public, no credential.
- **B — API key / Bearer:** the API takes a static key or Bearer token.
- **C — Managed identity:** the API accepts **Microsoft Entra ID tokens** (Azure services, Azure
  Functions, or your own Entra-app-protected API).

---

## Create the OpenAPI tool & toolbox

Three ways to do the same thing — create the tool, add it to a toolbox, publish, and copy the
endpoint into your agent's `TOOLBOX_ENDPOINT`. Each method supports all three auth types (**A**
anonymous / **B** API key / **C** managed identity). For type **C**, also complete
[Configure managed-identity authorization](#configure-managed-identity-authorization-azure).

### VS Code (Foundry Toolkit)

1. In the **Foundry Toolkit** view (signed in), open **Tool Catalog** → **Catalog** tab → **Toolboxes** → **Create Your Toolbox**.

   ![VS Code — Tool Catalog, Create Your Toolbox](../images/vsc-toolcatalog.png)
2. Enter a toolbox **Name** and description, then in the **Included** panel click **+ Add ▾** → **Add tools**.

   ![VS Code — Build a Custom Toolbox, Add tools](../images/vsc-toolbox-create.png)
3. In the **Select a tool** dialog, switch to the **Custom** tab and select **OpenAPI tool**.
   Paste/upload the OpenAPI 3.x spec, then set **Authentication**:
   - **A — Anonymous:** leave auth unset.
   - **B — API key:** pick or create a `CustomKeys` connection whose key name matches the spec's
     `securityScheme`.
   - **C — Managed identity:** enter the **Audience** for your target (resource URI for *C-RBAC*, or
     `api://<client-id>` for *C-App*).

   Click **Add Tools**.

   ![VS Code — Select a tool, Custom tab](../images/vsc-custom-tool.png)
4. Back on **Build a Custom Toolbox**, click **Publish**. The toolbox appears on the **Toolboxes**
   tab. Use the copy icon in the **Endpoint URL** column to copy the consumer MCP endpoint into your
   agent's `TOOLBOX_ENDPOINT` — or click **Scaffold code template** to generate a hosted agent
   wired to it.

   ![VS Code — Toolboxes list, copy endpoint URL](../images/vsc-copy-endpoint.png)

### CLI (`azd`)

**(Type B only) Create the connection:**

```bash
azd ai connection create myapiconn \
  --kind custom-keys \
  --target https://api.example.com \
  --custom-key "x-api-key=<api-key>" \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

**Way A (`toolbox.yaml`):**

```bash
azd ai toolbox create agent-tools --from-file ./toolbox.yaml --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT"
```

```yaml
# toolbox.yaml
description: openapi toolbox
tools:
  - type: openapi
    openapi:
      name: catfacts
      spec:
        openapi: "3.0.0"
        info: { title: Cat Facts, version: "1.0.0" }
        servers: [{ url: https://catfact.ninja }]
        paths:
          /fact:
            get:
              operationId: getFact
              responses: { "200": { description: ok } }
      # --- pick ONE auth block ---
      # A — Anonymous
      auth:
        type: anonymous

      # B — API key / Bearer (spec must also include security + securitySchemes; scheme name = connection key)
      # auth:
      #   type: project_connection
      #   security_scheme:
      #     project_connection_id: myapiconn

      # C — Managed identity, C-RBAC (audience = the service's resource URI)
      # auth:
      #   type: managed_identity
      #   security_scheme:
      #     audience: https://search.azure.com

      # C — Managed identity, C-App (audience = api://<client-id>)
      # auth:
      #   type: managed_identity
      #   security_scheme:
      #     audience: api://<client-id>
```

**Way B (`azure.yaml`)** — declares the toolbox and agent together (uses the same `auth` blocks
above):

```yaml
# azure.yaml
name: my-agent-project
services:
  agent-tools:
    host: azure.ai.toolbox
    tools:
      - type: openapi
        openapi:
          name: catfacts
          spec:
            openapi: "3.0.0"
            info: { title: Cat Facts, version: "1.0.0" }
            servers: [{ url: https://catfact.ninja }]
            paths:
              /fact:
                get:
                  operationId: getFact
                  responses: { "200": { description: ok } }
          auth:
            type: anonymous   # or B / C — see the auth blocks above
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

### Portal (Foundry)

1. In the [Foundry portal](https://ai.azure.com/), open **Tools** → **Toolboxes** tab →
   **Create toolbox**. Give it a **Name**.
2. Under **Included**, click **+ Add** → **Add tool** → the **Custom** tab → **OpenAPI tool** →
   **Create**.
3. In the dialog, paste/upload the OpenAPI spec and choose the auth type:
   - **A — Anonymous:** nothing else to set.
   - **B — API key:** pick or create a `CustomKeys` connection whose key name matches the spec's
     `securityScheme`.
   - **C — Managed identity:** enter the **Audience** for your target (resource URI for
     [*C-RBAC*](#c-rbac--azure-resource-with-rbac), or `api://<client-id>` for
     [*C-App*](#c-app--api-behind-an-entra-app-registration)), then complete
     [Configure managed-identity authorization](#configure-managed-identity-authorization-azure).

   Click **Connect**.
4. Click **Publish** and copy the endpoint into `TOOLBOX_ENDPOINT`.

![Foundry portal — Create an OpenAPI tool (spec + auth)](../images/portal-openapi.png)

![Foundry portal — OpenAPI spec filled](../images/portal-openapi-filled.png)

![Foundry portal — published toolbox (endpoint)](../images/portal-web-search-detail.png)

---

## Configure managed-identity authorization (Azure)

*Only auth type **C** needs this. **A** and **B** are done after
[Create the OpenAPI tool & toolbox](#create-the-openapi-tool--toolbox).*

The agent calls the target with the **Foundry account's managed identity** — no stored key. For it to
work, two things must match:

- **Audience** — the resource identifier of the *target*, set on the tool. (It's **not** your Foundry
  endpoint. A mismatch is the usual cause of a `401` — decode the token at [jwt.ms](https://jwt.ms)
  and check the `aud` claim.)
- **Authorization** — the target must let this identity in. How you do that depends on the target:
  **[C-RBAC](#c-rbac--azure-resource-with-rbac)** for an Azure resource, or
  **[C-App](#c-app--api-behind-an-entra-app-registration)** for your own API (Azure Functions, App
  Service, APIM…).

### Step 1 — enable the identity and get its IDs

Turn on the Foundry account's system-assigned identity and note two IDs: the **object ID** (used
everywhere) and the **application (client) ID** (used only for *C-App*).

**CLI:**

```bash
az cognitiveservices account identity assign -n <foundry-account> -g <rg>
PRINCIPAL=$(az cognitiveservices account show -n <foundry-account> -g <rg> --query identity.principalId -o tsv)  # object ID
APP_ID=$(az ad sp show --id "$PRINCIPAL" --query appId -o tsv)                                                   # client ID
```

**Portal:** **Foundry resource** (the account, not the project) → **Resource Management** →
**Identity** → copy the **Object (principal) ID**. For the client ID, search that object ID in
**Microsoft Entra ID** → **Overview** → **Application ID**.

### Step 2A — C-RBAC (Azure resource with RBAC)

For an Azure service that uses **RBAC** (Storage, AI Search, Key Vault, ARM…): set the audience to
the service's resource URI and grant the identity a role. No app registration needed.

| Target | Audience | Example role |
|---|---|---|
| Azure AI Search | `https://search.azure.com` | Search Index Data Reader |
| Azure Storage (Blob) | `https://storage.azure.com` | Storage Blob Data Reader |
| Azure Key Vault | `https://vault.azure.net` | Key Vault Secrets User |
| Azure Resource Manager | `https://management.azure.com` | Reader |

**Portal:** target resource → **Access control (IAM)** → **Add role assignment** → pick the role →
**Managed identity** → the **Foundry account** identity → **Review + assign**.

**CLI:**

```bash
az role assignment create --assignee "$PRINCIPAL" \
  --role "Search Index Data Reader" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Search/searchServices/<search-service>"
```

### Step 2B — C-App (your own API behind an Entra app)

For **your own API** (Azure Functions / App Service **Easy Auth**, or APIM with OAuth), the server
checks the token itself. It accepts the call only when **all three** match:

1. **Audience** = the app registration's **Application ID URI** (`api://<client-id>`, from **Expose
   an API**) — set this as the tool's audience.
2. **Issuer** = `https://login.microsoftonline.com/<tenant-id>/v2.0`.
3. **Allowed application** = the Foundry identity's **client ID** on the server's allow-list. *This is
   the step people forget* — its absence is the usual cause of a `401`.

**Portal (Azure Functions / App Service Easy Auth):** app → **Authentication** → **Add identity
provider** → **Microsoft**. Set **Client application requirement** → *specific client applications* →
add the identity's **client ID**; **Identity requirement** → *specific identities* → add its **object
ID**; **Unauthenticated requests** → **HTTP 401**. Then set the app registration's **Application ID
URI** to your app's URL so the audience matches.

**CLI (Azure Functions / App Service Easy Auth):**

```bash
SUB=<sub>; RG=<app-rg>; APP=<app-name>
TENANT=$(az account show --query tenantId -o tsv)
FUNC_APP_ID=<app-registration-client-id>   # the app protecting your API
# $APP_ID and $PRINCIPAL from Step 1 (the Foundry identity)

cat > authv2.json <<EOF
{ "properties": {
  "platform": { "enabled": true },
  "globalValidation": { "requireAuthentication": true, "unauthenticatedClientAction": "Return401" },
  "identityProviders": { "azureActiveDirectory": {
    "enabled": true,
    "registration": { "openIdIssuer": "https://login.microsoftonline.com/$TENANT/v2.0", "clientId": "$FUNC_APP_ID" },
    "validation": {
      "allowedAudiences": [ "api://$FUNC_APP_ID" ],
      "defaultAuthorizationPolicy": {
        "allowedApplications": [ "$APP_ID" ],
        "allowedPrincipals": { "identities": [ "$PRINCIPAL" ] }
      }
    }
  }}
}}
EOF

az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/authsettingsV2?api-version=2022-03-01" \
  --body @authv2.json
```

**APIM with OAuth:** add a `validate-jwt` policy that checks `aud` = `api://<client-id>`, the issuer,
and a `required-claims` match on `appid`/`azp` = the Foundry identity's client ID. Use the same
`api://<client-id>` as the tool audience.

> **Security:** if you delete the app, also delete its app registration — an orphaned Application ID
> URI can be re-claimed by another app and used to obtain tokens your identity trusts.

---

## Notes

- Every operation needs an `operationId` (letters, `-`, `_` only).
- Multiple `openapi` entries in one toolbox are allowed only if each spec has a distinct
  `info.title`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| API key not sent (type B) | Spec missing `securitySchemes` / `security`, or scheme name ≠ connection key | Add both sections; make the scheme `name` match the connection key. |
| `401`, role assigned (C-RBAC) | Audience doesn't match the target's resource identifier | Set `audience` to the service's resource URI; decode the token at [jwt.ms](https://jwt.ms) and check `aud`. |
| `401` from your own server (C-App) | Audience/issuer mismatch, or the identity's client ID isn't allow-listed | Set `audience` to `api://<client-id>`, confirm the v2 issuer, and add the identity's **client ID** to the server's allow-list. |
| `403` (token accepted) | Identity lacks permission | Grant the required **RBAC role** (C-RBAC), or confirm the correct client ID / object ID is allow-listed (C-App). |
| Token rejected by target | Target doesn't accept Microsoft Entra ID tokens | Use API key / Bearer auth (type B) instead. |

## References

- [OpenAPI tool documentation](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/openapi)
- [Secure OpenAPI tool calls from Foundry Agent Service (App Service / Azure Functions)](https://learn.microsoft.com/azure/app-service/configure-authentication-ai-foundry-openapi-tool)
