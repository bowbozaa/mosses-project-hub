[CmdletBinding()]
param(
    [string]$Topic = "Codex and Claude, establish a concise live collaboration protocol for this workspace. Do not modify files. Wait for the user's next goal.",
    [int]$MaxRounds = 6,
    [switch]$Continuous,
    [int]$DelaySeconds = 3,
    [string]$WorkingDirectory = ""
)

$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $WorkingDirectory = (Resolve-Path (Join-Path $ScriptRoot "..\..")).Path
}

$LogDir = Join-Path $ScriptRoot "logs"
$Runner = Join-Path $ScriptRoot "live-bridge.ps1"
$CodexLogPath = Join-Path $LogDir "codex.log"
$ClaudeLogPath = Join-Path $LogDir "claude.log"
$StopPath = Join-Path $LogDir "stop.txt"
$PidPath = Join-Path $LogDir "bridge.pid"
$RunnerStdOutPath = Join-Path $LogDir "runner.stdout.log"
$RunnerStdErrPath = Join-Path $LogDir "runner.stderr.log"

function Format-ProcessArgument {
    param([string]$Argument)

    if ($Argument -match '[\s"]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }

    return $Argument
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RunnerStdOutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RunnerStdErrPath -Force -ErrorAction SilentlyContinue

Set-Content -LiteralPath $CodexLogPath -Value "Starting Codex live view..." -Encoding utf8
Set-Content -LiteralPath $ClaudeLogPath -Value "Starting Claude live view..." -Encoding utf8

$codexView = "& { `$host.UI.RawUI.WindowTitle = 'Codex Live View'; Get-Content -LiteralPath '$CodexLogPath' -Wait }"
$claudeView = "& { `$host.UI.RawUI.WindowTitle = 'Claude Live View'; Get-Content -LiteralPath '$ClaudeLogPath' -Wait }"

Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $codexView)
Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $claudeView)

$runnerArgs = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $Runner,
    "-Topic", $Topic,
    "-MaxRounds", $MaxRounds,
    "-DelaySeconds", $DelaySeconds,
    "-WorkingDirectory", $WorkingDirectory,
    "-LogDir", $LogDir
)

if ($Continuous) {
    $runnerArgs += "-Continuous"
}

$runnerArgumentLine = ($runnerArgs | ForEach-Object { Format-ProcessArgument $_ }) -join " "
$process = Start-Process powershell.exe `
    -ArgumentList $runnerArgumentLine `
    -WindowStyle Hidden `
    -RedirectStandardOutput $RunnerStdOutPath `
    -RedirectStandardError $RunnerStdErrPath `
    -PassThru
Set-Content -LiteralPath $PidPath -Value $process.Id -Encoding ascii

Write-Host "Claude/Codex live bridge started."
Write-Host "Bridge PID: $($process.Id)"
Write-Host "Codex view: $CodexLogPath"
Write-Host "Claude view: $ClaudeLogPath"
Write-Host "Transcript: $(Join-Path $LogDir 'transcript.md')"
Write-Host "Stop: .\.agents\claude-codex-live\Stop-LiveAiChat.ps1"
