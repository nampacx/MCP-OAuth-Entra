# MCP-OAuth-Entra

This repository demonstrates how to build an **OAuth-protected MCP server** on Azure that integrates with **Microsoft AI Foundry** agents using [OAuth Identity Passthrough](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/identity-passthrough).

Identity Passthrough lets an AI Foundry agent call downstream services on behalf of the signed-in user, forwarding the user's Entra ID token rather than the agent's own managed identity. For this to work the downstream service must:

1. Be a proper OAuth resource server (validate Bearer tokens issued by Entra ID)
2. Advertise itself via [RFC 9728](https://www.rfc-editor.org/rfc/rfc9728) Protected Resource Metadata so clients can discover the correct authorization server

This sample is the downstream service. It keeps things deliberately simple: an ASP.NET Core 9 app that exposes a single `get_user` MCP tool, which reads all claims from the forwarded JWT and returns them as a key-value map. That makes it easy to verify end-to-end that the right user identity is flowing through.

## How it works

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
MCP Server validates JWT ──► executes tool ──► returns result
```

The server also exposes a local OAuth proxy (`/authorize`, `/callback`, `/token`) so that MCP clients that implement the authorization-server discovery flow (e.g. command-line tools, local test scripts) can complete the sign-in without requiring a separately registered client application.

## Repository structure

```text
├── deploy/
│   ├── 01-Provision.ps1   # Register Entra ID app + deploy Azure infrastructure
│   └── 02-Deploy.ps1      # Build, package, and deploy the app to App Service
├── iac/
│   ├── main.bicep                    # Linux App Service Plan + Web App (AVM)
│   ├── main.bicepparam               # Deployment parameters
│   └── bicepconfig.json
├── src/
│   ├── McpOAuthEntra.sln
│   └── McpOAuthEntra/
│       ├── Program.cs                # Auth + OAuth proxy endpoints + MCP server
│       ├── AuthProxy/
│       │   └── AuthProxyEndpoints.cs # OAuth discovery + proxy endpoints
│       ├── Tools/UserTool.cs         # get_user MCP tool
│       ├── Properties/launchSettings.json
│       ├── appsettings.json
│       └── appsettings.Development.json  # git-ignored — use dotnet user-secrets
└── test/
    └── Test-McpEndpoint.ps1          # End-to-end test (6 steps)
```

## Prerequisites

| Tool               | Minimum version |
| ------------------ | --------------- |
| .NET SDK           | 9.0             |
| Azure CLI          | 2.65            |
| Bicep CLI          | 0.29            |
| PowerShell         | 7.3             |
| Azure subscription | —               |
| Entra ID tenant    | —               |

---

## 1 — Provision (Entra ID + Azure infrastructure)

```powershell
.\deploy\01-Provision.ps1 -ResourceGroup 'rg-mcp-oauth-entra' -Location 'westeurope'
```

The script is idempotent — safe to re-run. It executes seven steps in the correct order to eliminate the chicken-and-egg dependency between the app registration and the infrastructure:

| Step | Action |
| ---- | ------ |
| 1 | Create / update the Entra ID app registration |
| 2 | Configure v2 tokens, optional claims (`given_name`, `family_name`, `upn`), and required Graph permissions |
| 3 | Expose the `user_impersonation` delegated scope |
| 4 | Pre-authorize the Azure CLI for frictionless local token acquisition |
| 5 | Register `http://localhost:5000/callback` |
| 6 | Create resource group and deploy Bicep (ClientId/TenantId injected automatically) |
| 7 | Register `https://<app>.azurewebsites.net/callback` using the hostname from step 6 |

The script prints the `TenantId`, `ClientId`, and ready-to-paste `dotnet user-secrets` commands at the end.

---

## 2 — Local development

Set credentials via user-secrets (the commands are printed by `01-Provision.ps1`):

```powershell
dotnet user-secrets set "AzureAd:TenantId" "<tenant-id>" --project src/McpOAuthEntra
dotnet user-secrets set "AzureAd:ClientId" "<client-id>" --project src/McpOAuthEntra
```

Run the server:

```powershell
dotnet run --project src/McpOAuthEntra
```

The MCP endpoint is at `http://localhost:5000/mcp`.

---

## 3 — Deploy the application

```powershell
.\deploy\02-Deploy.ps1 -ResourceGroup 'rg-mcp-oauth-entra'
```

---

## 4 — Test

With the server running:

```powershell
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>'

# Against the deployed App Service:
.\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>' `
    -ServerUrl 'https://<app>.azurewebsites.net'
```

| Step | Assertion |
| ---- | --------- |
| 1 | Unauthenticated POST returns `401` with `WWW-Authenticate: Bearer resource_metadata="..."` |
| 2 | `/.well-known/oauth-protected-resource` returns valid PRM JSON |
| 3 | `az account get-access-token` returns a Bearer token |
| 4 | MCP `initialize` handshake succeeds |
| 5 | `tools/list` response includes `get_user` |
| 6 | `tools/call get_user` returns the authenticated user's JWT claims |

---

## The `get_user` tool

Returns all non-empty claims from the forwarded JWT as a key-value map. This is intentionally complete — when used with AI Foundry Identity Passthrough you can inspect exactly which claims arrive and use them in your agent logic.

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

> **Personal Microsoft accounts** (live.com, outlook.com, etc.) do not populate `given_name` / `family_name` even with optional claims configured — only the `name` claim (full display name) is available.

---

## Bicep IaC

Uses [Azure Verified Modules (AVM)](https://azure.github.io/Azure-Verified-Modules/) from `mcr.microsoft.com/bicep/avm/res`:

| Module                   | Purpose                  |
| ------------------------ | ------------------------ |
| `avm/res/web/serverfarm` | Linux App Service Plan   |
| `avm/res/web/site`       | Web App (DOTNETCORE 9.0) |

Verify the pinned versions in `iac/main.bicep` against the [AVM catalog](https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/) before deploying to production.

---

## Security notes

- HTTPS-only enforced at App Service level and via `UseHttpsRedirection()`
- FTPS disabled, minimum TLS 1.2
- System-assigned managed identity enabled for future Key Vault integration
- Both v1 (`sts.windows.net`) and v2 (`login.microsoftonline.com`) token issuers accepted
- `appsettings.Development.json` is git-ignored — use `dotnet user-secrets` for local credentials
