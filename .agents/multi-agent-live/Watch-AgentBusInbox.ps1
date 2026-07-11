[CmdletBinding()]
param(
    [string]$AgentList = "codex,claude,friday-mcp,claude-sessions,friday-mesh-health",
    [int]$MaxRounds = 1,
    [int]$DelaySeconds = 1,
    [int]$PollSeconds = 3,
    [string]$WorkingDirectory = "",
    [string]$AgentConfigPath = "",
    [string]$InboxPath = "",
    [string]$LogDir = ""
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

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $ScriptRoot "logs"
}

if ([string]::IsNullOrWhiteSpace($InboxPath)) {
    $InboxPath = Join-Path $ScriptRoot "inbox.md"
}

$RunsDir = Join-Path $LogDir "runs"
$CombinedTranscriptPath = Join-Path $LogDir "cursor-transcript.md"
$StopPath = Join-Path $LogDir "stop.txt"
$WatcherLogPath = Join-Path $LogDir "cursor-inbox.log"
$LastHashPath = Join-Path $LogDir "cursor-inbox.last-hash"
$Runner = Join-Path $ScriptRoot "Invoke-AgentBus.ps1"

function Write-SharedFile {
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
        try { $writer.Write($Value) }
        finally { $writer.Dispose() }
    }
    finally {
        $stream.Dispose()
    }
}

function Add-SharedContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        try { $writer.WriteLine($Value) }
        finally { $writer.Dispose() }
    }
    finally {
        $stream.Dispose()
    }
}

function Write-WatcherLog {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-SharedContent -Path $WatcherLogPath -Value "[$stamp] $Message"
}

function Get-InboxMessage {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $content = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match($content, '(?s)^## Message\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) { return "" }

    $message = $match.Groups[1].Value.Trim()
    $message = $message -replace '(?m)^<!--.*?-->$', ''
    $message = $message.Trim()

    if ($message -match '^\s*$') { return "" }
    if ($message -match 'เขียนงานใหม่ตรงนี้|write the next task here') { return "" }

    return $message
}

function Get-HashText {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Format-Argument {
    param([string]$Argument)
    if ($Argument -match '[\s"]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }
    return $Argument
}

New-Item -ItemType Directory -Force -Path $LogDir, $RunsDir | Out-Null

if (-not (Test-Path -LiteralPath $InboxPath)) {
    Write-SharedFile -Path $InboxPath -Value @"
# Cursor Multi-Agent Inbox

พิมพ์งานใหม่ใต้หัวข้อ `## Message` แล้วบันทึกไฟล์นี้
watcher จะเรียก agents เฉพาะเมื่อข้อความเปลี่ยน

## Message
<!-- เขียนงานใหม่ตรงนี้ / write the next task here -->
"@
}

if (-not (Test-Path -LiteralPath $CombinedTranscriptPath)) {
    Write-SharedFile -Path $CombinedTranscriptPath -Value "# Cursor Multi-Agent Transcript`n`nStarted: $(Get-Date -Format o)`nAgents: $AgentList`nInbox: $InboxPath`n"
}

Write-SharedFile -Path $WatcherLogPath -Value "=== CURSOR INBOX WATCHER ===`nStarted: $(Get-Date -Format o)`nInbox: $InboxPath`nTranscript: $CombinedTranscriptPath`n"
Write-WatcherLog "Watcher started. Agents=$AgentList MaxRounds=$MaxRounds PollSeconds=$PollSeconds"

$lastHash = ""
if (Test-Path -LiteralPath $LastHashPath) {
    $lastHash = (Get-Content -Raw -LiteralPath $LastHashPath).Trim()
}

while ($true) {
    if (Test-Path -LiteralPath $StopPath) {
        Write-WatcherLog "Stop file detected."
        break
    }

    try {
        $message = Get-InboxMessage -Path $InboxPath
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $hash = Get-HashText -Text $message
            if ($hash -ne $lastHash) {
                $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $runDir = Join-Path $RunsDir $stamp
                New-Item -ItemType Directory -Force -Path $runDir | Out-Null

                Write-WatcherLog "New inbox message detected. Run=$stamp"
                Add-SharedContent -Path $CombinedTranscriptPath -Value "`n---`n`n## Inbox message $stamp`n$message`n"

                $args = @(
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy", "Bypass",
                    "-File", $Runner,
                    "-Topic", $message,
                    "-AgentList", $AgentList,
                    "-MaxRounds", [string]$MaxRounds,
                    "-DelaySeconds", [string]$DelaySeconds,
                    "-WorkingDirectory", $WorkingDirectory,
                    "-LogDir", $runDir,
                    "-AgentConfigPath", $AgentConfigPath
                )
                $argumentLine = ($args | ForEach-Object { Format-Argument $_ }) -join " "
                $process = Start-Process powershell.exe `
                    -ArgumentList $argumentLine `
                    -WindowStyle Hidden `
                    -Wait `
                    -PassThru

                if ($process.ExitCode -ne 0) {
                    Write-WatcherLog "Agent run exited with code $($process.ExitCode)."
                }

                $runTranscript = Join-Path $runDir "transcript.md"
                if (Test-Path -LiteralPath $runTranscript) {
                    $result = Get-Content -Raw -LiteralPath $runTranscript
                    Add-SharedContent -Path $CombinedTranscriptPath -Value "`n## Agent result $stamp`n$result`n"
                }

                $lastHash = $hash
                Write-SharedFile -Path $LastHashPath -Value $lastHash
                Write-WatcherLog "Run complete. Run=$stamp"
            }
        }
    }
    catch {
        Write-WatcherLog "ERROR: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollSeconds
}

Write-WatcherLog "Watcher stopped."
