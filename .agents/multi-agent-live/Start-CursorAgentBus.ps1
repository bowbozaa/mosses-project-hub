[CmdletBinding()]
param(
    [string]$AgentList = "codex,claude,friday-mcp,claude-sessions,friday-mesh-health",
    [int]$MaxRounds = 1,
    [int]$DelaySeconds = 1,
    [int]$PollSeconds = 3,
    [string]$WorkingDirectory = "",
    [string]$AgentConfigPath = "",
    [switch]$OpenCursor
)

$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $WorkingDirectory = (Resolve-Path (Join-Path $ScriptRoot "..\..")).Path
}

if ([string]::IsNullOrWhiteSpace($AgentConfigPath)) {
    $AgentConfigPath = Join-Path $ScriptRoot "agents.json"
}

$LogDir = Join-Path $ScriptRoot "logs"
$InboxPath = Join-Path $ScriptRoot "inbox.md"
$TranscriptPath = Join-Path $LogDir "cursor-transcript.md"
$Watcher = Join-Path $ScriptRoot "Watch-AgentBusInbox.ps1"
$StopPath = Join-Path $LogDir "stop.txt"
$PidPath = Join-Path $LogDir "cursor-inbox.pid"
$StdOutPath = Join-Path $LogDir "cursor-inbox.stdout.log"
$StdErrPath = Join-Path $LogDir "cursor-inbox.stderr.log"

function Format-Argument {
    param([string]$Argument)
    if ($Argument -match '[\s"]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }
    return $Argument
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue

$args = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $Watcher,
    "-AgentList", $AgentList,
    "-MaxRounds", [string]$MaxRounds,
    "-DelaySeconds", [string]$DelaySeconds,
    "-PollSeconds", [string]$PollSeconds,
    "-WorkingDirectory", $WorkingDirectory,
    "-AgentConfigPath", $AgentConfigPath,
    "-InboxPath", $InboxPath,
    "-LogDir", $LogDir
)

$argumentLine = ($args | ForEach-Object { Format-Argument $_ }) -join " "
$process = Start-Process powershell.exe `
    -ArgumentList $argumentLine `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdOutPath `
    -RedirectStandardError $StdErrPath `
    -PassThru

Set-Content -LiteralPath $PidPath -Value $process.Id -Encoding ascii

if ($OpenCursor) {
    $cursorPath = Join-Path $env:LOCALAPPDATA "Programs\cursor\_\Cursor.exe"
    if (Test-Path -LiteralPath $cursorPath) {
        Start-Process -FilePath $cursorPath -ArgumentList @($WorkingDirectory)
        Start-Process -FilePath $cursorPath -ArgumentList @($InboxPath)
        Start-Process -FilePath $cursorPath -ArgumentList @($TranscriptPath)
    }
}

Write-Host "Cursor agent bus inbox watcher started."
Write-Host "Watcher PID: $($process.Id)"
Write-Host "Inbox: $InboxPath"
Write-Host "Transcript: $TranscriptPath"
Write-Host "Stop: .\.agents\multi-agent-live\Stop-AgentBus.ps1"
