[CmdletBinding()]
param(
    [string]$Topic = "Multi-agent live bus startup. Agents should report readiness and wait for the user's next concrete task.",
    [string]$AgentList = "codex,claude,claude-sessions,friday-mesh-health",
    [int]$MaxRounds = 3,
    [switch]$Continuous,
    [int]$DelaySeconds = 3,
    [string]$WorkingDirectory = "",
    [string]$AgentConfigPath = "",
    [switch]$NoWindows
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
$AgentLogDir = Join-Path $LogDir "agents"
$Runner = Join-Path $ScriptRoot "Invoke-AgentBus.ps1"
$StopPath = Join-Path $LogDir "stop.txt"
$PidPath = Join-Path $LogDir "bus.pid"
$RunnerStdOutPath = Join-Path $LogDir "runner.stdout.log"
$RunnerStdErrPath = Join-Path $LogDir "runner.stderr.log"
$TranscriptPath = Join-Path $LogDir "transcript.md"
$BusLogPath = Join-Path $LogDir "bus.log"

function Format-ProcessArgument {
    param([string]$Argument)

    if ($Argument -match '[\s"]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }

    return $Argument
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9_.-]', '_').ToLowerInvariant()
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        try {
            $writer.Write($Value)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

New-Item -ItemType Directory -Force -Path $AgentLogDir | Out-Null
Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RunnerStdOutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RunnerStdErrPath -Force -ErrorAction SilentlyContinue

Write-Utf8File -Path $TranscriptPath -Value "Starting multi-agent transcript..."
Write-Utf8File -Path $BusLogPath -Value "Starting multi-agent bus..."

$requestedAgents = @($AgentList -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne "all" })
foreach ($agentName in $requestedAgents) {
    $agentLogPath = Join-Path $AgentLogDir "$(Get-SafeName $agentName).log"
    Write-Utf8File -Path $agentLogPath -Value "Starting $agentName live view..."
}

if (-not $NoWindows) {
    $transcriptView = "& { `$host.UI.RawUI.WindowTitle = 'Agent Bus Transcript'; Get-Content -LiteralPath '$TranscriptPath' -Wait }"
    $busView = "& { `$host.UI.RawUI.WindowTitle = 'Agent Bus Log'; Get-Content -LiteralPath '$BusLogPath' -Wait }"
    Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $transcriptView)
    Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $busView)

    foreach ($agentName in $requestedAgents) {
        $agentLogPath = Join-Path $AgentLogDir "$(Get-SafeName $agentName).log"
        $agentView = "& { `$host.UI.RawUI.WindowTitle = 'Agent $agentName'; Get-Content -LiteralPath '$agentLogPath' -Wait }"
        Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $agentView)
    }
}

$runnerArgs = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $Runner,
    "-Topic", $Topic,
    "-AgentList", $AgentList,
    "-MaxRounds", $MaxRounds,
    "-DelaySeconds", $DelaySeconds,
    "-WorkingDirectory", $WorkingDirectory,
    "-LogDir", $LogDir,
    "-AgentConfigPath", $AgentConfigPath
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

Write-Host "Multi-agent live bus started."
Write-Host "Bus PID: $($process.Id)"
Write-Host "Agents: $AgentList"
Write-Host "Transcript: $TranscriptPath"
Write-Host "Bus log: $BusLogPath"
Write-Host "Agent logs: $AgentLogDir"
Write-Host "Stop: .\.agents\multi-agent-live\Stop-AgentBus.ps1"
