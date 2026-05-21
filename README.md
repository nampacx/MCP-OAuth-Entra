# 🔐 MCP-OAuth-Entra

This repository demonstrates how to build an **OAuth-protected MCP server** on Azure that integrates with **Microsoft AI Foundry** agents using [OAuth Identity Passthrough](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/mcp-authentication#oauth-identity-passthrough). 🚀

Identity Passthrough lets an AI Foundry agent call downstream services **on behalf of the signed-in user**, forwarding the user's Entra ID token rather than the agent's own managed identity. For this to work the downstream service must:

1. ✅ Be a proper OAuth resource server (validate Bearer tokens issued by Entra ID)
2. ✅ Advertise itself via [RFC 9728](https://www.rfc-editor.org/rfc/rfc9728) Protected Resource Metadata so clients can discover the correct authorization server

This sample is the downstream service. It keeps things deliberately simple: an ASP.NET Core 9 app that exposes a single `get_user` MCP tool, which reads all claims from the forwarded JWT and returns them as a key-value map. That makes it easy to verify end-to-end that the right user identity is flowing through. 🎯

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

---

## 📁 Repository structure

```text
├── deploy/
│   ├── _Shared.ps1        # Shared helpers (strict mode, Write-Step/OK/Skip)
│   ├── 01-Provision.ps1   # Register Entra ID app + deploy Azure infrastructure
│   ├── 02-Deploy.ps1      # Build, package, and deploy the app to App Service
│   └── 03-Cleanup.ps1     # Delete and purge all Azure resources
├── iac/
│   ├── main.bicep                    # Linux App Service Plan + Web App (AVM)
│   ├── foundry.bicep                 # AI Foundry account, project & model deployment
│   ├── main.bicepparam               # Deployment parameters
│   └── bicepconfig.json
├── src/
│   ├── McpOAuthEntra.sln
│   └── McpOAuthEntra/
│       ├── Program.cs                # Auth + MCP server
│       ├── Tools/UserTool.cs         # get_user MCP tool
│       ├── Properties/launchSettings.json
│       └── appsettings.json
└── test/
    └── Test-McpEndpoint.ps1          # End-to-end test (6 steps)
```

---

## 🛠️ Prerequisites

| Tool | Minimum version |
| ---- | --------------- |
| .NET SDK | 9.0 |
| Azure CLI | 2.65 |
| Bicep CLI | 0.29 |
| PowerShell | 7.3 |
| Azure subscription | — |
| Entra ID tenant | — |

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
| 1 | 📋 Create / update the Entra ID app registration |
| 2 | ⚙️ Configure v2 tokens, optional claims (`given_name`, `family_name`, `upn`), and required Graph permissions |
| 3 | 🔑 Expose the `user_impersonation` delegated scope |
| 4 | 💻 Pre-authorize the Azure CLI for frictionless local token acquisition |
| 5 | ☁️ Create resource group and deploy Bicep (ClientId/TenantId injected automatically) |
| 6 | 🤖 *(optional)* Deploy AI Foundry + Project + GPT-5.4 model to swedencentral (`-DeployFoundry`) |

At the end the script prints your `TenantId`, `ClientId`, and ready-to-paste `dotnet user-secrets` commands. 🎁

---

## 💻 Step 2 — Local development

Set credentials via user-secrets (the commands are printed by `01-Provision.ps1`):

```powershell
dotnet user-secrets set "AzureAd:TenantId" "<tenant-id>" --project src/McpOAuthEntra
dotnet user-secrets set "AzureAd:ClientId" "<client-id>" --project src/McpOAuthEntra
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

---

## 🧪 Step 4 — Test

With the server running, fire up the end-to-end test:

```powershell
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>'

# Against the deployed App Service:
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>' `
    -ServerUrl 'https://<app>.azurewebsites.net'
```

| Step | What's verified |
| ---- | --------------- |
| 1 | 🔒 Unauthenticated POST returns `401` with `WWW-Authenticate: Bearer resource_metadata="..."` |
| 2 | 📄 `/.well-known/oauth-protected-resource` returns valid PRM JSON |
| 3 | 🎫 `az account get-access-token` returns a Bearer token |
| 4 | 🤝 MCP `initialize` handshake succeeds |
| 5 | 🛠️ `tools/list` response includes `get_user` |
| 6 | 👤 `tools/call get_user` returns the authenticated user's JWT claims |

---

## 🧹 Step 5 — Cleanup

To remove all Azure resources (and optionally the Entra ID app registration):

```powershell
# Delete Azure resources only
.\deploy\03-Cleanup.ps1 -ResourceGroup 'rg-mcp-oauth-entra'

# Also delete the Entra ID app registration
.\deploy\03-Cleanup.ps1 -ResourceGroup 'rg-mcp-oauth-entra' -DeleteEntraApp
```

The script prompts for confirmation before deleting anything and handles soft-delete purging for Cognitive Services accounts created by `-DeployFoundry`.

---

## 🛠️ The `get_user` tool

Returns all non-empty claims from the forwarded JWT as a key-value map. This is intentionally complete — when used with AI Foundry Identity Passthrough you can inspect exactly which claims arrive and use them in your agent logic. 🔍

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

Uses [Azure Verified Modules (AVM)](https://azure.github.io/Azure-Verified-Modules/) from `mcr.microsoft.com/bicep/avm/res` for the App Service resources:

| Module | Purpose |
| ------ | ------- |
| `avm/res/web/serverfarm` | Linux App Service Plan |
| `avm/res/web/site` | Web App (DOTNETCORE 9.0) |

Verify the pinned versions in [iac/main.bicep](iac/main.bicep) against the [AVM catalog](https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/) before deploying to production.

---

## 🔒 Security notes

- HTTPS-only enforced at App Service level and via `UseHttpsRedirection()`
- FTPS disabled, minimum TLS 1.2
- System-assigned managed identity enabled for future Key Vault integration
- Both v1 (`sts.windows.net`) and v2 (`login.microsoftonline.com`) token issuers accepted
- `appsettings.Development.json` is git-ignored — use `dotnet user-secrets` for local credentials
