[CmdletBinding()]
param(
    [switch]$Kill
)

$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$LogDir = Join-Path $ScriptRoot "logs"
$StopPath = Join-Path $LogDir "stop.txt"
$PidPath = Join-Path $LogDir "bridge.pid"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Set-Content -LiteralPath $StopPath -Value "stop requested at $(Get-Date -Format o)" -Encoding utf8

if ($Kill -and (Test-Path -LiteralPath $PidPath)) {
    $pidValue = (Get-Content -Raw -LiteralPath $PidPath).Trim()
    if ($pidValue -match '^\d+$') {
        $process = Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force
            Write-Host "Bridge process killed: $($process.Id)"
            exit 0
        }
    }
}

Write-Host "Stop requested. The bridge will stop after the current model call finishes."
