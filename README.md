# 🔐 MCP-OAuth-Entra

This repository demonstrates how to build an **OAuth-protected MCP server** on Azure that integrates with **Microsoft AI Foundry** agents using [OAuth Identity Passthrough](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/mcp-authentication#oauth-identity-passthrough). 🚀

Identity Passthrough lets an AI Foundry agent call downstream services **on behalf of the signed-in user**, forwarding the user's Entra ID token rather than the agent's own managed identity. For this to work the downstream service must:

1. ✅ Be a proper OAuth resource server (validate Bearer tokens issued by Entra ID)
2. ✅ Advertise itself via [RFC 9728](https://www.rfc-editor.org/rfc/rfc9728) Protected Resource Metadata so clients can discover the correct authorization server

This sample is the downstream service. It exposes two MCP tools:

- **`get_user`** — returns all claims from the forwarded JWT as a key-value map, making it easy to verify that the right user identity is flowing through
- **`get_graph_profile`** — exchanges the incoming token for a Graph-scoped token via the [OAuth 2.0 On-Behalf-Of flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow) and returns the user's Microsoft Graph profile

---

## 🏗️ How it works

```text
AI Foundry Agent (or any MCP client)
  │
  │  POST /mcp  ← no token
  ▼
MCP Server ──► 401  WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource"
  │
  │  GET /.well-known/oauth-protected-resource          (RFC 9728)
  ▼  { "resource": "api://<client-id>",
  │    "authorization_servers": ["https://login.microsoftonline.com/<tenant-id>/v2.0"] }
  │
  │  (client follows authorization_servers to obtain a token for the resource)
  │
  │  POST /mcp  Authorization: Bearer <Entra ID token>
  ▼
MCP Server validates JWT ──► executes tool ──► returns result 🎉
```

For `get_graph_profile` the server additionally performs an OBO exchange to acquire a Graph-scoped token before calling `GET /me`.

---

## 📁 Repository structure

```text
├── deploy/
│   ├── _Shared.ps1        # Shared helpers (strict mode, Write-Step/OK/Skip)
│   ├── 01-Provision.ps1   # Register Entra ID app + deploy Azure infrastructure
│   ├── 02-Deploy.ps1      # Build, package, and deploy the app to App Service
│   └── 03-Cleanup.ps1     # Delete and purge all Azure resources
├── iac/
│   ├── main.bicep                    # App Service Plan + Web App + Key Vault (AVM)
│   ├── foundry.bicep                 # AI Foundry account, project & model deployment
│   ├── main.bicepparam               # Deployment parameters
│   └── bicepconfig.json
├── src/
│   ├── McpOAuthEntra.sln
│   └── McpOAuthEntra/
│       ├── Program.cs                # Auth + MCP server
│       ├── Services/GraphService.cs  # OBO flow → Microsoft Graph
│       ├── Tools/UserTool.cs         # get_user + get_graph_profile MCP tools
│       ├── Properties/launchSettings.json
│       └── appsettings.json
└── test/
    └── Test-McpEndpoint.ps1          # End-to-end test (6 steps, configurable tool)
```

---

## 🚀 Step 1 — Provision (Entra ID + Azure infrastructure)

```powershell
.\deploy\01-Provision.ps1 -ResourceGroup 'rg-mcp-oauth-entra' -Location 'westeurope'
```

Want AI Foundry too? Add `-DeployFoundry` and everything is set up in one go — including a **GPT-5.4 GlobalStandard** model deployment in `swedencentral` (widest model coverage 🌍):

```powershell
.\deploy\01-Provision.ps1 -ResourceGroup 'rg-mcp-oauth-entra' -Location 'westeurope' -DeployFoundry
```

The script is **idempotent** — safe to re-run after partial failures. It executes steps in the correct order to eliminate the chicken-and-egg dependency between the app registration and the infrastructure:

| Step | What happens |
| ---- | ------------ |
| 1 | 📋 Create / update the Entra ID app registration and service principal |
| 2 | ⚙️ Configure v2 tokens, optional claims (`given_name`, `family_name`, `upn`), Graph permissions (`openid`, `profile`, `email`, `User.Read`), and grant tenant-wide admin consent |
| 3 | 🔑 Expose the `user_impersonation` delegated scope |
| 4 | 💻 Pre-authorize the Azure CLI for frictionless local token acquisition |
| 5 | ☁️ Deploy Bicep — App Service + Key Vault; ClientId/TenantId/deploying-user OID injected automatically |
| 6 | 🔐 Create a 1-year client secret and store it in Key Vault (never printed to the console) |
| 7 | 🤖 *(optional)* Deploy AI Foundry + Project + GPT-5.4 model to swedencentral (`-DeployFoundry`) |

> ⚠️ **Admin consent** — step 2 attempts `az ad app permission admin-consent` automatically. If the caller lacks *Cloud Application Administrator* or higher, the command is skipped and a portal deep-link is printed. Without consent the OBO flow will fail with `AADSTS65001` at runtime.

At the end the script prints your `TenantId`, `ClientId`, Key Vault name, and a ready-to-run command to load the client secret into `dotnet user-secrets`. 🎁

---

## 💻 Step 2 — Local development

Set credentials via user-secrets (the commands are printed by `01-Provision.ps1`):

```powershell
dotnet user-secrets set "AzureAd:TenantId" "<tenant-id>" --project src/McpOAuthEntra
dotnet user-secrets set "AzureAd:ClientId" "<client-id>" --project src/McpOAuthEntra

# Read the client secret directly from Key Vault — value never appears on screen
az keyvault secret show --vault-name '<kv-name>' --name 'client-secret' --query value -o tsv `
    | dotnet user-secrets set "AzureAd:ClientSecret" --project src/McpOAuthEntra
```

Run the server:

```powershell
dotnet run --project src/McpOAuthEntra
```

The MCP endpoint is live at `http://localhost:5000/mcp` ✨

---

## ☁️ Step 3 — Deploy the application

```powershell
.\deploy\02-Deploy.ps1 -ResourceGroup 'rg-mcp-oauth-entra'
```

In production the App Service reads `AzureAd:ClientSecret` from a Key Vault reference resolved via its system-assigned managed identity — no secrets in app settings or environment variables.

---

## 🧪 Step 4 — Test

With the server running, fire up the end-to-end test:

```powershell
# Default: calls get_user
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>'

# Call get_graph_profile instead
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>' -ToolName 'get_graph_profile'

# Against the deployed App Service
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>' `
    -ServerUrl 'https://<app>.azurewebsites.net' -ToolName 'get_graph_profile'
```

| Step | What's verified |
| ---- | --------------- |
| 1 | 🔒 Unauthenticated POST returns `401` with `WWW-Authenticate: Bearer resource_metadata="..."` |
| 2 | 📄 `/.well-known/oauth-protected-resource` returns valid PRM JSON |
| 3 | 🎫 `az account get-access-token` returns a Bearer token |
| 4 | 🤝 MCP `initialize` handshake succeeds |
| 5 | 🛠️ `tools/list` response includes the requested tool |
| 6 | 👤 `tools/call <tool>` returns the result |

---

## 🧹 Step 5 — Cleanup

To remove all Azure resources (and optionally the Entra ID app registration):

```powershell
# Delete Azure resources only
.\deploy\03-Cleanup.ps1 -ResourceGroup 'rg-mcp-oauth-entra'

# Also delete the Entra ID app registration
.\deploy\03-Cleanup.ps1 -ResourceGroup 'rg-mcp-oauth-entra' -DeleteEntraApp
```

The script prompts for confirmation, then removes resources in the correct order: Foundry resource group → purge Cognitive Services → main resource group → purge Key Vault → (optional) Entra ID app registration.

---

## 🛠️ MCP tools

### `get_user`

Returns all non-empty claims from the forwarded JWT as a key-value map. Useful for verifying end-to-end that the right user identity is flowing through.

```json
{
  "preferred_username": "user@contoso.com",
  "given_name": "Jane",
  "family_name": "Doe",
  "name": "Jane Doe",
  "oid": "...",
  "tid": "...",
  ...
}
```

> 💡 **Personal Microsoft accounts** (live.com, outlook.com, etc.) do not populate `given_name` / `family_name` even with optional claims configured — only the `name` claim (full display name) is available.

### `get_graph_profile`

Exchanges the incoming Bearer token for a Graph-scoped token via the **OAuth 2.0 On-Behalf-Of flow**, then calls `GET /me` to return the user's Microsoft Graph profile.

```json
{
  "displayName": "Jane Doe",
  "userPrincipalName": "user@contoso.com",
  "mail": "user@contoso.com",
  "givenName": "Jane",
  "surname": "Doe",
  "jobTitle": "Engineer",
  "department": "Platform",
  "officeLocation": "Amsterdam",
  "id": "..."
}
```

The OBO flow requires the app registration's client secret, which is stored in Key Vault and injected into the App Service at runtime via a managed-identity Key Vault reference.

---

## 🤖 Azure AI Foundry (optional)

When provisioned with `-DeployFoundry`, the script deploys a complete AI Foundry setup to `swedencentral`:

| Resource | Details |
| -------- | ------- |
| Foundry account | `Microsoft.CognitiveServices/accounts` — `AIServices` kind |
| Foundry project | `Microsoft.CognitiveServices/accounts/projects` |
| Model deployment | `gpt-5.4` · GlobalStandard · 500K TPM |

Connect your Foundry agent to the MCP server using **OAuth Identity Passthrough** so agents act on behalf of the signed-in user — no shared secrets, full user context preserved. 🙌

---

## 📦 Bicep IaC

Uses [Azure Verified Modules (AVM)](https://azure.github.io/Azure-Verified-Modules/) for all resources:

| Module | Purpose |
| ------ | ------- |
| `avm/res/web/serverfarm` | Linux App Service Plan |
| `avm/res/web/site` | Web App (DOTNETCORE 9.0) |
| `avm/res/key-vault/vault` | Key Vault (stores the client secret) |

The Key Vault `roleAssignments` in [iac/main.bicep](iac/main.bicep) grant two roles:

| Principal | Role |
| --------- | ---- |
| Web App system-assigned MI | `Key Vault Secrets User` — read secrets at runtime |
| Deploying user (OID injected by script) | `Key Vault Secrets Officer` — write the client secret during provisioning |

Verify the pinned module versions against the [AVM catalog](https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/) before deploying to production.

---

## 🔒 Security notes

- HTTPS-only enforced at App Service level and via `UseHttpsRedirection()`
- FTPS disabled, minimum TLS 1.2
- Client secret stored in Key Vault; injected via App Service Key Vault reference — never in app settings or environment variables in plain text
- System-assigned managed identity used for Key Vault access — no credential management required in production
- OBO flow exchanges the user's incoming token for a narrowly scoped Graph token — the client secret never leaves the server
- Both v1 (`sts.windows.net`) and v2 (`login.microsoftonline.com`) token issuers accepted
- `AzureAd:ClientSecret` for local development is loaded from Key Vault via `az keyvault secret show` and stored in `dotnet user-secrets` — never committed to source control
