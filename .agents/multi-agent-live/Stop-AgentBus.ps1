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
$PidPath = Join-Path $LogDir "bus.pid"
$InboxPidPath = Join-Path $LogDir "cursor-inbox.pid"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Set-Content -LiteralPath $StopPath -Value "stop requested at $(Get-Date -Format o)" -Encoding utf8

if ($Kill) {
    foreach ($path in @($PidPath, $InboxPidPath)) {
        if (Test-Path -LiteralPath $path) {
            $pidValue = (Get-Content -Raw -LiteralPath $path).Trim()
            if ($pidValue -match '^\d+$') {
                $process = Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
                if ($process) {
                    Stop-Process -Id $process.Id -Force
                    Write-Host "Stopped process: $($process.Id)"
                }
            }
        }
    }
    exit 0
}

Write-Host "Stop requested. The agent bus will stop after the current agent call finishes."
