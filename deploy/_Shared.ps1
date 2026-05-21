Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string] $msg) { Write-Host "`n[$msg]" -ForegroundColor Cyan }
function Write-OK  ([string] $msg) { Write-Host "      $msg" -ForegroundColor Green }
function Write-Skip([string] $msg) { Write-Host "      $msg" -ForegroundColor Yellow }
