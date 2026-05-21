#Requires -Version 7
<#
.SYNOPSIS
    Registers the Entra ID app and provisions Azure infrastructure in one pass.

.DESCRIPTION
    Solves the chicken-and-egg dependency between the app registration and the
    infrastructure deployment by running them in the correct order:

    1.  Create / update the Entra ID app registration  →  obtain ClientId + TenantId
    2.  Configure token version, optional claims, and required Graph permissions
    3.  Expose the user_impersonation delegated scope
    4.  Pre-authorize the Azure CLI for frictionless local token acquisition
    5.  Register http://localhost:5000/callback (local dev redirect URI)
    6.  Create resource group and deploy Azure infrastructure (Bicep)
         ClientId and TenantId are injected as parameter overrides — no need
         to edit iac/main.bicepparam manually before running this script.
    7.  Register https://<appservice>/callback (production redirect URI)

    The script is idempotent — safe to re-run after partial failures.

.PARAMETER DisplayName
    Display name for the Entra ID app registration.

.PARAMETER ResourceGroup
    Azure resource group to create or reuse.

.PARAMETER Location
    Azure region for the resource group and all resources.

.PARAMETER AppName
    Prefix for Azure resource names (3-15 alphanumeric characters).

.PARAMETER AppServicePlanSku
    App Service Plan SKU.

.PARAMETER SignInAudience
    Entra ID sign-in audience for the app registration.
#>

[CmdletBinding()]
param(
    [string] $DisplayName       = 'MCP OAuth Entra',
    [string] $ResourceGroup     = 'rg-mcp-oauth-entra',
    [string] $Location          = 'westeurope',
    [string] $AppName           = 'mcp-entra',
    [string] $AppServicePlanSku = 'B1',
    [string] $SignInAudience    = 'AzureADMyOrg'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = Resolve-Path "$PSScriptRoot\.."
$bicepFile  = Join-Path $repoRoot 'iac\main.bicep'
$paramsFile = Join-Path $repoRoot 'iac\main.bicepparam'

if (-not (Test-Path $bicepFile))  { throw "Bicep template not found: $bicepFile"  }
if (-not (Test-Path $paramsFile)) { throw "Parameter file not found: $paramsFile" }

function Write-Step([string] $msg) { Write-Host "`n[$msg]" -ForegroundColor Cyan }
function Write-OK  ([string] $msg) { Write-Host "      $msg" -ForegroundColor Green }
function Write-Skip([string] $msg) { Write-Host "      $msg" -ForegroundColor Yellow }

# ── 1. Create / update app registration ──────────────────────────────────────

Write-Step '1/7  Creating / updating Entra ID app registration'

$app = az ad app create `
    --display-name $DisplayName `
    --sign-in-audience $SignInAudience `
    | ConvertFrom-Json

$clientId = $app.appId
$objectId = $app.id
$tenantId = az account show --query tenantId -o tsv

Write-OK "ClientId = $clientId   TenantId = $tenantId"

# ── 2. Configure token version, optional claims, Graph permissions ────────────

Write-Step '2/7  Configuring token version, optional claims, and Graph permissions'

$graphToken  = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$graphUri    = "https://graph.microsoft.com/v1.0/applications/$objectId"
$graphHeaders = @{ Authorization = "Bearer $graphToken" }

az ad app update --id $clientId --identifier-uris "api://$clientId" | Out-Null

$configBody = @{
    api            = @{ requestedAccessTokenVersion = 2 }
    optionalClaims = @{
        accessToken = @(
            @{ name = 'given_name';  essential = $false; additionalProperties = @() }
            @{ name = 'family_name'; essential = $false; additionalProperties = @() }
            @{ name = 'upn';         essential = $false; additionalProperties = @() }
        )
    }
    requiredResourceAccess = @(
        @{
            resourceAppId  = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
            resourceAccess = @(
                @{ id = '37f7f235-527c-4136-accd-4a02d197296e'; type = 'Scope' }  # openid
                @{ id = '14dad69e-099b-42c9-810b-d002981feec1'; type = 'Scope' }  # profile
                @{ id = '64a6cdd6-aab1-4aaf-94b8-3cc8405e90d6'; type = 'Scope' }  # email
            )
        }
    )
} | ConvertTo-Json -Depth 7

Invoke-RestMethod -Method PATCH -Uri $graphUri -Headers $graphHeaders `
    -ContentType 'application/json' -Body $configBody | Out-Null

Write-OK 'Token v2, optional claims (given_name, family_name, upn), Graph openid/profile/email.'

# ── 3. Expose user_impersonation scope ────────────────────────────────────────

Write-Step '3/7  Exposing user_impersonation delegated scope'

$currentApp    = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $graphHeaders
$existingScope = $currentApp.api.oauth2PermissionScopes |
                     Where-Object { $_.value -eq 'user_impersonation' } |
                     Select-Object -First 1

if ($existingScope) {
    $scopeId = $existingScope.id
    Write-Skip "Scope already exists (id: $scopeId) — skipping."
}
else {
    $scopeId   = [guid]::NewGuid().ToString()
    $scopeBody = @{
        api = @{
            oauth2PermissionScopes = @(
                @{
                    adminConsentDescription = 'Allow the app to access the MCP server on behalf of the user.'
                    adminConsentDisplayName = 'Access MCP server'
                    id                      = $scopeId
                    isEnabled               = $true
                    type                    = 'User'
                    userConsentDescription  = 'Allow this app to access the MCP server on your behalf.'
                    userConsentDisplayName  = 'Access MCP server'
                    value                   = 'user_impersonation'
                }
            )
        }
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method PATCH -Uri $graphUri -Headers $graphHeaders `
        -ContentType 'application/json' -Body $scopeBody | Out-Null

    Write-OK "Scope added (id: $scopeId)."
}

# ── 4. Pre-authorize the Azure CLI ────────────────────────────────────────────

Write-Step '4/7  Pre-authorizing the Azure CLI'

# Well-known Azure CLI app ID (constant across all tenants).
$azureCliAppId  = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$currentApp     = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $graphHeaders
$alreadyPreAuth = $currentApp.api.preAuthorizedApplications |
                      Where-Object { $_.appId -eq $azureCliAppId }

if ($alreadyPreAuth) {
    Write-Skip 'Azure CLI already pre-authorized — skipping.'
}
else {
    $preAuthBody = @{
        api = @{
            preAuthorizedApplications = @(
                @{
                    appId                  = $azureCliAppId
                    delegatedPermissionIds = @($scopeId)
                }
            )
        }
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method PATCH -Uri $graphUri -Headers $graphHeaders `
        -ContentType 'application/json' -Body $preAuthBody | Out-Null

    Write-OK 'Azure CLI pre-authorized — no consent prompt needed for local testing.'
}

# ── 5. Register localhost redirect URI ────────────────────────────────────────

Write-Step '5/7  Registering http://localhost:5000/callback redirect URI'

function Add-RedirectUri([string[]] $urisToAdd) {
    $app      = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $graphHeaders
    $existing = @($app.publicClient.redirectUris)
    $missing  = @($urisToAdd | Where-Object { $_ -notin $existing })

    if ($missing.Count -eq 0) {
        Write-Skip 'All redirect URIs already registered — skipping.'
        return
    }

    $updated = @($existing + $missing | Sort-Object -Unique)
    $body    = @{
        isFallbackPublicClient = $true
        publicClient           = @{ redirectUris = $updated }
    } | ConvertTo-Json -Depth 3

    Invoke-RestMethod -Method PATCH -Uri $graphUri -Headers $graphHeaders `
        -ContentType 'application/json' -Body $body | Out-Null

    Write-OK "Registered: $($missing -join ', ')"
}

Add-RedirectUri 'http://localhost:5000/callback'

# ── 6. Create resource group and deploy Bicep ─────────────────────────────────

Write-Step "6/7  Deploying Azure infrastructure to '$ResourceGroup' ($Location)"

az group create --name $ResourceGroup --location $Location | Out-Null

# ClientId and TenantId are injected as overrides — main.bicepparam placeholders
# are not required to be filled in before running this script.
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file  $bicepFile `
    --parameters     $paramsFile `
    --parameters     "tenantId=$tenantId" "clientId=$clientId" `
                     "appName=$AppName"   "appServicePlanSku=$AppServicePlanSku"

$outputs = az deployment group show `
    --resource-group $ResourceGroup `
    --name           main `
    --query          'properties.outputs' `
    -o json `
    | ConvertFrom-Json

$hostname = $outputs.webAppHostname.value
Write-OK "App Service deployed: $hostname"

# ── 7. Register Azure App Service redirect URI ────────────────────────────────

Write-Step '7/7  Registering Azure App Service callback redirect URI'

Add-RedirectUri "https://$hostname/callback"

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Provisioning complete.' -ForegroundColor Green
Write-Host ''
Write-Host '  Entra ID'
Write-Host "    TenantId  : $tenantId"
Write-Host "    ClientId  : $clientId"
Write-Host "    Scope     : api://$clientId/user_impersonation"
Write-Host ''
Write-Host '  Azure'
Write-Host "    Resource Group : $ResourceGroup"
Write-Host "    MCP endpoint : $($outputs.mcpEndpointUrl.value)"
Write-Host "    PRM URL      : $($outputs.prmUrl.value)"
Write-Host "    App name     : $($outputs.webAppName.value)"
Write-Host ''
Write-Host '  Local development — set user-secrets:'
Write-Host "    dotnet user-secrets set ""AzureAd:TenantId"" ""$tenantId"" --project src/McpOAuthEntra"
Write-Host "    dotnet user-secrets set ""AzureAd:ClientId"" ""$clientId"" --project src/McpOAuthEntra"
Write-Host ''
Write-Host "  Next step: .\deploy\02-Deploy.ps1 -ResourceGroup '$ResourceGroup'" -ForegroundColor Yellow
