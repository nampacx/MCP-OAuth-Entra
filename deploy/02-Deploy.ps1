#Requires -Version 7
<#
.SYNOPSIS
    Builds, packages, and deploys the MCP server to Azure App Service.

.DESCRIPTION
    - Runs 'dotnet publish' in Release mode
    - Compresses the output into a ZIP package
    - Uploads the package to the App Service via 'az webapp deploy'
    - Prints the live MCP endpoint URL

.PARAMETER ResourceGroup
    Name of the resource group where the App Service lives.

.PARAMETER SkipBuild
    Skip dotnet publish and reuse an existing ./publish output folder.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,
    [switch] $SkipBuild
)

. "$PSScriptRoot\_Shared.ps1"

$repoRoot    = Resolve-Path "$PSScriptRoot\.."
$projectFile = Join-Path $repoRoot 'src\McpOAuthEntra\McpOAuthEntra.csproj'
$publishDir  = Join-Path $repoRoot 'publish'
$zipPath     = Join-Path $repoRoot 'app.zip'

# ── 1. Build ──────────────────────────────────────────────────────────────────

if (-not $SkipBuild) {
    Write-Step "1/4  Building and publishing in Release mode"

    if (-not (Test-Path $projectFile)) { throw "Project file not found: $projectFile" }
    if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

    dotnet publish $projectFile -c Release -o $publishDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit code $LASTEXITCODE)." }

    Write-OK 'Build succeeded.'
}
else {
    Write-Step "1/4  Skipping build"
    Write-Skip "Reusing existing '$publishDir'."
    if (-not (Test-Path $publishDir)) { throw "Publish folder not found: $publishDir" }
}

# ── 2. Package ────────────────────────────────────────────────────────────────

Write-Step '2/4  Creating deployment package'

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath

Write-OK 'Package created.'

# ── 3. Resolve App Service name ───────────────────────────────────────────────

Write-Step '3/4  Resolving App Service name from deployment outputs'

$outputs = az deployment group show `
    --resource-group $ResourceGroup `
    --name           main `
    --query          'properties.outputs' `
    -o json | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($outputs.webAppName.value)) {
    throw "Could not read webAppName from deployment outputs. Run 01-Provision.ps1 first."
}

$appName = $outputs.webAppName.value
Write-OK "App Service: $appName"

# ── 4. Deploy ─────────────────────────────────────────────────────────────────

Write-Step "4/4  Deploying to '$appName'"

az webapp deploy `
    --resource-group $ResourceGroup `
    --name           $appName `
    --src-path       $zipPath `
    --type           zip

Write-OK 'Deployment complete.'

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  MCP server is live:' -ForegroundColor Green
Write-Host "    Endpoint : $($outputs.mcpEndpointUrl.value)"
Write-Host "    PRM URL  : $($outputs.prmUrl.value)"
Write-Host ''
