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
    8.  (Optional) Deploy Azure AI Foundry Hub + Project to swedencentral

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

.PARAMETER DeployFoundry
    When set, also deploys an Azure AI Foundry Hub and Project to swedencentral,
    which provides the widest model coverage for Identity Passthrough testing.

.PARAMETER FoundryResourceGroup
    Resource group for the Foundry resources. Defaults to <ResourceGroup>-ai.
#>

[CmdletBinding()]
param(
    [string] $DisplayName          = 'MCP OAuth Entra',
    [string] $ResourceGroup        = 'rg-mcp-oauth-entra',
    [string] $Location             = 'westeurope',
    [string] $AppName              = 'mk-mcp',
    [string] $AppServicePlanSku    = 'B1',
    [string] $SignInAudience       = 'AzureADMyOrg',
    [switch] $DeployFoundry,
    [string] $FoundryResourceGroup = ''
)

. "$PSScriptRoot\_Shared.ps1"

if (-not $FoundryResourceGroup) { $FoundryResourceGroup = "$ResourceGroup-ai" }

$instance = 'https://login.microsoftonline.com'

$repoRoot         = Resolve-Path "$PSScriptRoot\.."
$bicepFile        = Join-Path $repoRoot 'iac\main.bicep'
$paramsFile       = Join-Path $repoRoot 'iac\main.bicepparam'
$foundryBicepFile = Join-Path $repoRoot 'iac\foundry.bicep'

if (-not (Test-Path $bicepFile))  { throw "Bicep template not found: $bicepFile"  }
if (-not (Test-Path $paramsFile)) { throw "Parameter file not found: $paramsFile" }
if ($DeployFoundry -and -not (Test-Path $foundryBicepFile)) {
    throw "Foundry Bicep template not found: $foundryBicepFile"
}

$totalSteps = if ($DeployFoundry) { 7 } else { 6 }

# ── 1. Create / update app registration ──────────────────────────────────────

Write-Step "1/$totalSteps  Creating / updating Entra ID app registration"

$app = az ad app create `
    --display-name $DisplayName `
    --sign-in-audience $SignInAudience `
    | ConvertFrom-Json

$clientId = $app.appId
$objectId = $app.id
$tenantId = az account show --query tenantId -o tsv

Write-OK "ClientId = $clientId   TenantId = $tenantId"

# A service principal must exist before admin consent can be granted.
az ad sp show --id $clientId -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    az ad sp create --id $clientId -o none
    Write-OK 'Service principal created.'
}
else {
    Write-Skip 'Service principal already exists — skipping.'
}

# ── 2. Configure token version, optional claims, Graph permissions ────────────

Write-Step "2/$totalSteps  Configuring token version, optional claims, and Graph permissions"

$graphToken   = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$graphUri     = "https://graph.microsoft.com/v1.0/applications/$objectId"
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
                @{ id = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'; type = 'Scope' }  # User.Read
            )
        }
    )
} | ConvertTo-Json -Depth 7

Invoke-RestMethod -Method PATCH -Uri $graphUri -Headers $graphHeaders `
    -ContentType 'application/json' -Body $configBody | Out-Null

Write-OK 'Token v2, optional claims (given_name, family_name, upn), Graph openid/profile/email/User.Read.'

# Grant tenant-wide admin consent so the OBO flow can exchange tokens for Graph
# without an interactive consent prompt (AADSTS65001). Requires Cloud Application
# Administrator or higher. Falls back to a portal link if the caller lacks the role.
az ad app permission admin-consent --id $clientId -o none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-OK 'Admin consent granted for Graph permissions.'
}
else {
    Write-Skip 'Admin consent could not be granted automatically — insufficient privileges or propagation delay.'
    Write-Skip "  Grant it in the portal: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$clientId"
    Write-Skip '  Without consent the OBO flow will fail with AADSTS65001 at runtime.'
}

# ── 3. Expose user_impersonation scope ────────────────────────────────────────

Write-Step "3/$totalSteps  Exposing user_impersonation delegated scope"

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

Write-Step "4/$totalSteps  Pre-authorizing the Azure CLI"

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

# ── 5. Create resource group and deploy Bicep ─────────────────────────────────

Write-Step "5/$totalSteps  Deploying Azure infrastructure to '$ResourceGroup' ($Location)"

az group create --name $ResourceGroup --location $Location | Out-Null

$deployingUserObjectId = az ad signed-in-user show --query id -o tsv

# ClientId, TenantId, and the deploying user's OID are injected as overrides —
# main.bicepparam placeholders are not required to be filled in before running this script.
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file  $bicepFile `
    --parameters     $paramsFile `
    --parameters     "tenantId=$tenantId" "clientId=$clientId" `
                     "appName=$AppName"   "appServicePlanSku=$AppServicePlanSku" `
                     "deployingUserObjectId=$deployingUserObjectId" `
    -o none

$outputs = az deployment group show `
    --resource-group $ResourceGroup `
    --name           main `
    --query          'properties.outputs' `
    -o json `
    | ConvertFrom-Json

Write-OK "App Service deployed: $($outputs.webAppHostname.value)"

# ── 6. Create client secret and store in Key Vault ────────────────────────────

Write-Step "6/$totalSteps  Creating and storing client secret in Key Vault"

# Re-acquire a fresh Graph token — the earlier one may have expired during deployment.
$graphToken   = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$graphHeaders = @{ Authorization = "Bearer $graphToken" }

$secretBody = @{
    passwordCredential = @{
        displayName = 'MCP OAuth Entra – provisioned'
        endDateTime = (Get-Date).AddYears(1).ToString('o')
    }
} | ConvertTo-Json -Depth 3

$secretResult = Invoke-RestMethod -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/applications/$objectId/addPassword" `
    -Headers $graphHeaders `
    -ContentType 'application/json' `
    -Body $secretBody

$clientSecret = $secretResult.secretText

# RBAC assignments can take up to ~60 s to propagate; retry until the write succeeds.
for ($attempt = 1; $attempt -le 5; $attempt++) {
    az keyvault secret set `
        --vault-name $outputs.keyVaultName.value `
        --name       'client-secret' `
        --value      $clientSecret `
        -o none
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 5) { throw "az keyvault secret set failed after 5 attempts." }
    Write-Skip "RBAC not yet propagated — retrying in 20 s ($attempt/5)..."
    Start-Sleep -Seconds 20
}

Write-OK "Secret stored in Key Vault '$($outputs.keyVaultName.value)' (expires $((Get-Date).AddYears(1).ToString('yyyy-MM-dd')))."

# ── 7. Deploy Azure AI Foundry (optional) ─────────────────────────────────────

if ($DeployFoundry) {
    Write-Step "7/$totalSteps  Deploying Azure AI Foundry to '$FoundryResourceGroup' (swedencentral)"

    az group create --name $FoundryResourceGroup --location swedencentral | Out-Null

    az deployment group create `
        --resource-group $FoundryResourceGroup `
        --name           foundry `
        --template-file  $foundryBicepFile `
        --parameters     "appName=$AppName" `
        -o none

    $foundryOutputs = az deployment group show `
        --resource-group $FoundryResourceGroup `
        --name           foundry `
        --query          'properties.outputs' `
        -o json `
        | ConvertFrom-Json

    Write-OK "Foundry : $($foundryOutputs.foundryName.value)"
    Write-OK "Project : $($foundryOutputs.projectName.value)"
}

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
Write-Host "    Resource group : $ResourceGroup ($Location)"
Write-Host "    App name       : $($outputs.webAppName.value)"
Write-Host "    Key Vault      : $($outputs.keyVaultName.value)"
Write-Host ''
Write-Host '  Endpoints'
Write-Host "    MCP            : $($outputs.mcpEndpointUrl.value)"
Write-Host "    PRM            : $($outputs.prmUrl.value)"
if ($DeployFoundry) {
    Write-Host ''
    Write-Host '  Azure AI Foundry (swedencentral)'
    Write-Host "    Resource group : $FoundryResourceGroup"
    Write-Host "    Foundry        : $($foundryOutputs.foundryName.value)"
    Write-Host "    Project        : $($foundryOutputs.projectName.value)"
    Write-Host "    Portal         : https://ai.azure.com"
}
Write-Host ''
Write-Host '  Foundry connection — OAuth Identity Passthrough'
Write-Host "    Client ID    : $clientId"
Write-Host "    Auth URL     : $instance/$tenantId/oauth2/v2.0/authorize"
Write-Host "    Token URL    : $instance/$tenantId/oauth2/v2.0/token"
Write-Host "    Refresh URL  : $instance/$tenantId/oauth2/v2.0/token"
Write-Host "    Scopes       : api://$clientId/user_impersonation"
Write-Host ''
Write-Host '  Local development — set user-secrets:'
Write-Host "    dotnet user-secrets set ""AzureAd:TenantId""     ""$tenantId""     --project src/McpOAuthEntra"
Write-Host "    dotnet user-secrets set ""AzureAd:ClientId""     ""$clientId""     --project src/McpOAuthEntra"
Write-Host "    az keyvault secret show --vault-name '$($outputs.keyVaultName.value)' --name 'client-secret' --query value -o tsv | dotnet user-secrets set ""AzureAd:ClientSecret"" --project src/McpOAuthEntra"
Write-Host ''
Write-Host "  Next step: .\deploy\02-Deploy.ps1 -ResourceGroup '$ResourceGroup'" -ForegroundColor Yellow
