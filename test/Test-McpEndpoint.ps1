#Requires -Version 7.3
<#
.SYNOPSIS
    End-to-end test of the MCP server's get_user tool.

.DESCRIPTION
    1. Acquires a Bearer token via the Azure CLI
    2. Verifies the unauthenticated flow returns 401 with the expected WWW-Authenticate header
    3. Verifies the Protected Resource Metadata endpoint
    4. Sends an MCP initialize handshake
    5. Lists available tools and asserts get_user is present
    6. Calls get_user and prints the result

.PARAMETER ServerUrl
    Base URL of the running MCP server. Defaults to http://localhost:5000.

.PARAMETER ClientId
    Entra ID Application (Client) ID.

.PARAMETER TenantId
    Entra ID Tenant (Directory) ID.

.EXAMPLE
    .\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>'

.EXAMPLE
    # Against the deployed App Service
    .\test\Test-McpEndpoint.ps1 -ClientId '<client-id>' -TenantId '<tenant-id>' `
        -ServerUrl 'https://<app>.azurewebsites.net'
#>

[CmdletBinding()]
param(
    [string] $ServerUrl = 'http://localhost:5000',

    [Parameter(Mandatory)]
    [string] $ClientId,

    [Parameter(Mandatory)]
    [string] $TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Step([string] $msg) {
    Write-Host "`n  $msg" -ForegroundColor Cyan
}

function Write-Pass([string] $msg) {
    Write-Host "  [PASS] $msg" -ForegroundColor Green
}

function Write-Fail([string] $msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    throw $msg
}

# MCP session ID — set by Invoke-Mcp after initialize, reused for all subsequent calls.
$script:McpSessionId = $null

# Wrapper that forces HTTP/1.1, handles SSE responses, and manages the MCP session ID.
# After initialize the server returns Mcp-Session-Id; every subsequent request must
# echo it back. This function captures and injects it automatically.
function Invoke-Mcp {
    param([hashtable] $Params)
    $Params['HttpVersion'] = '1.1'
    if ($ServerUrl -match 'localhost|127\.0\.0\.1' -and $ServerUrl -match '^https') {
        $Params['SkipCertificateCheck'] = $true
    }

    # Inject session ID into headers for all requests after initialize.
    if ($script:McpSessionId) {
        if (-not $Params.ContainsKey('Headers')) { $Params['Headers'] = @{} }
        $Params['Headers']['Mcp-Session-Id'] = $script:McpSessionId
    }

    $raw = Invoke-WebRequest @Params

    # Persist session ID returned by the server.
    # Use a case-insensitive search: App Service's reverse proxy lowercases headers
    # (mcp-session-id), but PowerShell's response dictionary may be case-sensitive.
    $sidEntry = $raw.Headers.GetEnumerator() |
                Where-Object  { $_.Key -ieq 'mcp-session-id' } |
                Select-Object -First 1
    if ($sidEntry) { $script:McpSessionId = ($sidEntry.Value -join '').Trim() }

    # The server may reply with SSE (text/event-stream) even for single responses.
    # Extract the first "data: {...}" line and return it as a parsed object.
    $ct = ($raw.Headers['Content-Type'] -join ',')
    if ($ct -match 'text/event-stream') {
        $dataLine = ($raw.Content -split "`n") |
                    Where-Object { $_ -match '^data:\s*\{' } |
                    Select-Object -First 1
        if (-not $dataLine) { throw "No JSON data event in SSE response:`n$($raw.Content)" }
        return ($dataLine -replace '^data:\s*', '') | ConvertFrom-Json
    }

    return $raw.Content | ConvertFrom-Json
}

# ── Setup ─────────────────────────────────────────────────────────────────────

$mcpUrl  = "$ServerUrl/mcp"
$prmUrl  = "$ServerUrl/.well-known/oauth-protected-resource"

Write-Host ""
Write-Host "  MCP server : $mcpUrl"
Write-Host "  ClientId   : $ClientId"
Write-Host "  TenantId   : $TenantId"

# ── 1. Unauthenticated request must return 401 ────────────────────────────────

Write-Step "1/6  Unauthenticated request → expect 401"

$unauthParams = @{
    Uri                = $mcpUrl
    Method             = 'POST'
    ContentType        = 'application/json'
    Body               = '{"jsonrpc":"2.0","method":"initialize","id":0}'
    SkipHttpErrorCheck = $true
    HttpVersion        = '1.1'
}
if ($ServerUrl -match 'localhost|127\.0\.0\.1' -and $ServerUrl -match '^https') {
    $unauthParams['SkipCertificateCheck'] = $true
}
$response401 = Invoke-WebRequest @unauthParams

if ($response401.StatusCode -ne 401) {
    Write-Fail "Expected 401 but got $($response401.StatusCode)"
}

$wwwAuth = $response401.Headers['WWW-Authenticate']
if ($wwwAuth -notmatch 'resource_metadata') {
    Write-Fail "WWW-Authenticate header missing 'resource_metadata': $wwwAuth"
}

Write-Pass "401 returned with WWW-Authenticate: $wwwAuth"

# ── 2. Protected Resource Metadata ────────────────────────────────────────────

Write-Step "2/6  GET /.well-known/oauth-protected-resource"

$prm = Invoke-Mcp @{ Uri = $prmUrl; Method = 'GET' }

if ($prm.resource -ne "api://$ClientId") {
    Write-Fail "PRM 'resource' mismatch: $($prm.resource)"
}
if ($prm.authorization_servers.Count -eq 0) {
    Write-Fail "PRM 'authorization_servers' is empty"
}

Write-Pass "PRM ok — authorization server: $($prm.authorization_servers[0])"

# ── 3. Acquire Bearer token via Azure CLI ─────────────────────────────────────

Write-Step "3/6  Acquiring Bearer token (az account get-access-token)..."

$token = az account get-access-token `
    --scope "api://$ClientId/user_impersonation" `
    --query accessToken -o tsv

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Fail "az account get-access-token returned an empty token. Run 'az login' first."
}

Write-Pass "Token acquired ($($token.Length) chars)"

$headers = @{
    Authorization = "Bearer $token"
    Accept        = 'application/json, text/event-stream'
}

# ── 4. MCP initialize ─────────────────────────────────────────────────────────

Write-Step "4/6  MCP initialize handshake"

$initBody = @{
    jsonrpc = '2.0'
    method  = 'initialize'
    params  = @{
        protocolVersion = '2024-11-05'
        capabilities    = @{}
        clientInfo      = @{ name = 'ps-test'; version = '1.0' }
    }
    id = 1
} | ConvertTo-Json -Depth 5

$init = Invoke-Mcp @{
    Uri         = $mcpUrl
    Method      = 'POST'
    ContentType = 'application/json'
    Headers     = $headers
    Body        = $initBody
}

if ($init.result.protocolVersion -notmatch '^\d{4}-\d{2}-\d{2}$') {
    Write-Fail "Unexpected protocolVersion: $($init.result.protocolVersion)"
}

Write-Pass "Initialized — server: $($init.result.serverInfo.name) $($init.result.serverInfo.version)"

# ── 5. List tools and assert get_user is present ──────────────────────────────

Write-Step "5/6  tools/list — asserting 'get_user' is available"

$toolList = Invoke-Mcp @{
    Uri         = $mcpUrl
    Method      = 'POST'
    ContentType = 'application/json'
    Headers     = $headers
    Body        = '{"jsonrpc":"2.0","method":"tools/list","id":2}'
}

$getUserTool = $toolList.result.tools | Where-Object { $_.name -eq 'get_user' }
if (-not $getUserTool) {
    Write-Fail "Tool 'get_user' not found in tools/list response"
}

Write-Pass "'get_user' found — description: $($getUserTool.description)"

# ── 6. Call get_user and print the result ─────────────────────────────────────

Write-Step "6/6  tools/call get_user"

$callBody = @{
    jsonrpc = '2.0'
    method  = 'tools/call'
    params  = @{ name = 'get_user'; arguments = @{} }
    id      = 3
} | ConvertTo-Json -Depth 5

$callResult = Invoke-Mcp @{
    Uri         = $mcpUrl
    Method      = 'POST'
    ContentType = 'application/json'
    Headers     = $headers
    Body        = $callBody
}

Write-Pass "get_user returned:"
Write-Host ""
$callResult.result.content | ForEach-Object {
    if ($_.type -eq 'text') {
        ($_.text | ConvertFrom-Json).PSObject.Properties |
            Sort-Object Name |
            ForEach-Object { Write-Host ("    {0,-55} {1}" -f $_.Name, $_.Value) }
    }
}
Write-Host ""
Write-Host "  All tests passed." -ForegroundColor Green
