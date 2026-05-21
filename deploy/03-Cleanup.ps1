#Requires -Version 7
<#
.SYNOPSIS
    Deletes and purges all Azure resources deployed by 01-Provision.ps1.

.DESCRIPTION
    Removes resources in the correct order:

    1.  Collect the Cognitive Services account name before deletion
        (soft-deleted accounts must be purged by name + location)
    2.  Delete the Foundry resource group
    3.  Purge the soft-deleted Cognitive Services account
    4.  Delete the main App Service resource group
    5.  (Optional) Delete the Entra ID app registration

.PARAMETER ResourceGroup
    Main resource group created by 01-Provision.ps1.

.PARAMETER FoundryResourceGroup
    Foundry resource group. Defaults to <ResourceGroup>-ai.

.PARAMETER AppName
    Resource name prefix used during provisioning.

.PARAMETER DisplayName
    Display name of the Entra ID app registration to delete.

.PARAMETER DeleteEntraApp
    When set, also deletes the Entra ID app registration.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ResourceGroup        = 'rg-npx-mcp-oauth-entra',
    [string] $FoundryResourceGroup = '',
    [string] $AppName              = 'mcp-entra',
    [string] $DisplayName          = 'MCP OAuth Entra',
    [switch] $DeleteEntraApp
)

. "$PSScriptRoot\_Shared.ps1"

if (-not $FoundryResourceGroup) { $FoundryResourceGroup = "$ResourceGroup-ai" }

# ── Confirmation ──────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  This will permanently delete:' -ForegroundColor Yellow
Write-Host "    Resource group : $ResourceGroup"
Write-Host "    Resource group : $FoundryResourceGroup"
if ($DeleteEntraApp) {
    Write-Host "    Entra ID app   : $DisplayName"
}
Write-Host ''
$confirm = Read-Host '  Type YES to continue'
if ($confirm -ne 'YES') {
    Write-Host '  Aborted.' -ForegroundColor Yellow
    exit 0
}

# ── 1. Collect Cognitive Services account name before deletion ─────────────────

Write-Step '1  Collecting Foundry resource info'

$cogAccount = $null

$foundryRgExists = az group exists --name $FoundryResourceGroup | ConvertFrom-Json
if ($foundryRgExists) {
    $cogAccount = az resource list `
        --resource-group $FoundryResourceGroup `
        --resource-type 'Microsoft.CognitiveServices/accounts' `
        --query '[0].{name:name, location:location}' `
        -o json | ConvertFrom-Json

    if ($cogAccount) {
        Write-OK "Found Cognitive Services account '$($cogAccount.name)' in $($cogAccount.location)"
    }
    else {
        Write-Skip 'No Cognitive Services account found in Foundry resource group.'
    }
}
else {
    Write-Skip "Resource group '$FoundryResourceGroup' does not exist — skipping."
}

# ── 2. Delete Foundry resource group ──────────────────────────────────────────

Write-Step '2  Deleting Foundry resource group'

if ($foundryRgExists) {
    az group delete --name $FoundryResourceGroup --yes
    Write-OK "Deleted '$FoundryResourceGroup'."
}
else {
    Write-Skip 'Already gone.'
}

# ── 3. Purge soft-deleted Cognitive Services account ──────────────────────────

Write-Step '3  Purging soft-deleted Cognitive Services account'

if ($cogAccount) {
    az cognitiveservices account purge `
        --name           $cogAccount.name `
        --resource-group $FoundryResourceGroup `
        --location       $cogAccount.location

    Write-OK "Purged '$($cogAccount.name)'."
}
else {
    Write-Skip 'Nothing to purge.'
}

# ── 4. Collect Key Vault name before deletion ──────────────────────────────────

Write-Step '4  Collecting Key Vault info'

$keyVault = $null

$mainRgExists = az group exists --name $ResourceGroup | ConvertFrom-Json
if ($mainRgExists) {
    $keyVault = az resource list `
        --resource-group $ResourceGroup `
        --resource-type  'Microsoft.KeyVault/vaults' `
        --query          '[0].{name:name, location:location}' `
        -o json | ConvertFrom-Json

    if ($keyVault) {
        Write-OK "Found Key Vault '$($keyVault.name)' in $($keyVault.location)."
    }
    else {
        Write-Skip 'No Key Vault found in main resource group.'
    }
}
else {
    Write-Skip "Resource group '$ResourceGroup' does not exist — skipping."
}

# ── 5. Delete main resource group ─────────────────────────────────────────────

Write-Step '5  Deleting main resource group'

if ($mainRgExists) {
    az group delete --name $ResourceGroup --yes
    Write-OK "Deleted '$ResourceGroup'."
}
else {
    Write-Skip 'Already gone.'
}

# ── 6. Purge soft-deleted Key Vault ───────────────────────────────────────────

Write-Step '6  Purging soft-deleted Key Vault'

if ($keyVault) {
    az keyvault purge --name $keyVault.name --location $keyVault.location --no-wait
    Write-OK "Purged '$($keyVault.name)'."
}
else {
    Write-Skip 'Nothing to purge.'
}

# ── 7. Delete Entra ID app registration (optional) ────────────────────────────

if ($DeleteEntraApp) {
    Write-Step '7  Deleting Entra ID app registration'

    $apps = az ad app list --display-name $DisplayName -o json | ConvertFrom-Json

    if ($apps.Count -eq 0) {
        Write-Skip "No app registration found with display name '$DisplayName'."
    }
    elseif ($apps.Count -gt 1) {
        Write-Host "      Found $($apps.Count) app registrations named '$DisplayName':" -ForegroundColor Yellow
        $apps | ForEach-Object { Write-Host "        $($_.appId)  $($_.displayName)" }
        Write-Host "      Delete them manually at https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps" -ForegroundColor Yellow
    }
    else {
        az ad app delete --id $apps[0].appId
        Write-OK "Deleted app registration '$DisplayName' ($($apps[0].appId))."
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Cleanup complete.' -ForegroundColor Green
Write-Host ''
