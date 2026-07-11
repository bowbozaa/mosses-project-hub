[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Topic,

    [int]$MaxRounds = 6,
    [switch]$Continuous,
    [int]$DelaySeconds = 3,

    [string]$WorkingDirectory = "",
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

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $ScriptRoot "logs"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$script:ClaudeExe = (Get-Command claude.exe -CommandType Application -ErrorAction Stop).Source

$TranscriptPath = Join-Path $LogDir "transcript.md"
$CodexLogPath = Join-Path $LogDir "codex.log"
$ClaudeLogPath = Join-Path $LogDir "claude.log"
$BridgeLogPath = Join-Path $LogDir "bridge.log"
$StopPath = Join-Path $LogDir "stop.txt"
$StatusPath = Join-Path $LogDir "status.json"

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    Set-Content -LiteralPath $Path -Value $Value -Encoding utf8
}

function Add-Utf8Content {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    Add-Content -LiteralPath $Path -Value $Value -Encoding utf8
}

function Strip-Ansi {
    param([string]$Text)
    return $Text -replace "$([char]27)\[[0-?]*[ -/]*[@-~]", ""
}

function Write-BridgeLog {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Utf8Content -Path $BridgeLogPath -Value "[$stamp] $Message"
}

function Write-Status {
    param(
        [string]$State,
        [int]$Round,
        [string]$Speaker = ""
    )
    $status = [ordered]@{
        state = $State
        round = $Round
        speaker = $Speaker
        updatedAt = (Get-Date).ToString("o")
        stopFile = $StopPath
        transcript = $TranscriptPath
    }
    Write-Utf8File -Path $StatusPath -Value ($status | ConvertTo-Json -Depth 4)
}

function Format-RecentTranscript {
    param(
        [array]$Messages,
        [int]$Limit = 8
    )

    $start = [Math]::Max(0, $Messages.Count - $Limit)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = $start; $i -lt $Messages.Count; $i++) {
        $item = $Messages[$i]
        $lines.Add(("{0}: {1}" -f $item.Speaker, $item.Text))
    }
    return ($lines -join "`n`n")
}

function New-AgentPrompt {
    param(
        [string]$AgentName,
        [string]$OtherName,
        [array]$Messages
    )

    $recent = Format-RecentTranscript -Messages $Messages -Limit 8
    $latest = $Messages[-1]

    return @"
You are $AgentName in a supervised live relay with $OtherName.

Rules:
- Reply as $AgentName only.
- Keep the reply under 120 words.
- Do not run tools, edit files, ask for credentials, or claim you changed the machine.
- Move the collaboration forward in a concrete way.
- If there is no user task yet, establish a concise operating protocol and wait for the user's next goal.

Initial user goal:
$Topic

Recent transcript:
$recent

Latest message from $($latest.Speaker):
$($latest.Text)

Reply as ${AgentName}:
"@
}

function Invoke-CodexReply {
    param([string]$Prompt)

    $promptFile = Join-Path $LogDir "codex.prompt.txt"
    $lastFile = Join-Path $LogDir "codex.last.txt"
    $rawFile = Join-Path $LogDir "codex.raw.log"

    Write-Utf8File -Path $promptFile -Value $Prompt
    Remove-Item -LiteralPath $lastFile -Force -ErrorAction SilentlyContinue

    Push-Location $WorkingDirectory
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $nativePreferenceExists = Test-Path variable:PSNativeCommandUseErrorActionPreference
        if ($nativePreferenceExists) {
            $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        }

        try {
            $ErrorActionPreference = "Continue"
            if ($nativePreferenceExists) {
                $PSNativeCommandUseErrorActionPreference = $false
            }

            & {
                Get-Content -Raw -LiteralPath $promptFile |
                    & codex exec `
                        --ignore-user-config `
                        --ignore-rules `
                        --skip-git-repo-check `
                        --ephemeral `
                        --sandbox read-only `
                        --output-last-message $lastFile `
                        --color never `
                        -
            } *> $rawFile
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            if ($nativePreferenceExists) {
                $PSNativeCommandUseErrorActionPreference = $previousNativePreference
            }
        }

        if ($exitCode -ne 0) {
            $raw = ""
            if (Test-Path -LiteralPath $rawFile) {
                $raw = Get-Content -Raw -LiteralPath $rawFile
            }
            throw "codex exec failed with exit code $exitCode. $raw"
        }

        if (-not (Test-Path -LiteralPath $lastFile)) {
            throw "codex exec did not create $lastFile"
        }

        return (Strip-Ansi (Get-Content -Raw -LiteralPath $lastFile)).Trim()
    }
    finally {
        Pop-Location
    }
}

function Invoke-ClaudeReply {
    param([string]$Prompt)

    $promptFile = Join-Path $LogDir "claude.prompt.txt"
    $rawFile = Join-Path $LogDir "claude.raw.log"

    Write-Utf8File -Path $promptFile -Value $Prompt

    Push-Location $WorkingDirectory
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $nativePreferenceExists = Test-Path variable:PSNativeCommandUseErrorActionPreference
        if ($nativePreferenceExists) {
            $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        }

        try {
            $ErrorActionPreference = "Continue"
            if ($nativePreferenceExists) {
                $PSNativeCommandUseErrorActionPreference = $false
            }

            & {
                Get-Content -Raw -LiteralPath $promptFile |
                    & $script:ClaudeExe -p --output-format text --permission-mode dontAsk
            } *> $rawFile
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            if ($nativePreferenceExists) {
                $PSNativeCommandUseErrorActionPreference = $previousNativePreference
            }
        }

        if ($exitCode -ne 0) {
            $raw = ""
            if (Test-Path -LiteralPath $rawFile) {
                $raw = Get-Content -Raw -LiteralPath $rawFile
            }
            throw "claude -p failed with exit code $exitCode. $raw"
        }

        return (Strip-Ansi (Get-Content -Raw -LiteralPath $rawFile)).Trim()
    }
    finally {
        Pop-Location
    }
}

Write-Utf8File -Path $TranscriptPath -Value "# Claude Codex Live Transcript`n`nStarted: $(Get-Date -Format o)`nWorking directory: $WorkingDirectory`nStop file: $StopPath`n"
Write-Utf8File -Path $CodexLogPath -Value "=== CODEX LIVE VIEW ===`nStop with: .\.agents\claude-codex-live\Stop-LiveAiChat.ps1`n"
Write-Utf8File -Path $ClaudeLogPath -Value "=== CLAUDE LIVE VIEW ===`nStop with: .\.agents\claude-codex-live\Stop-LiveAiChat.ps1`n"
Write-Utf8File -Path $BridgeLogPath -Value "=== BRIDGE LOG ===`n"

$messages = @(
    [pscustomobject]@{
        Speaker = "USER"
        Text = $Topic
    }
)

Add-Utf8Content -Path $TranscriptPath -Value "## USER`n$Topic`n"
Write-BridgeLog "Bridge started. Continuous=$Continuous MaxRounds=$MaxRounds DelaySeconds=$DelaySeconds"
Write-Status -State "running" -Round 0 -Speaker "USER"

$round = 1
while ($true) {
    if (Test-Path -LiteralPath $StopPath) {
        Write-BridgeLog "Stop file detected before round $round."
        break
    }

    if (-not $Continuous -and $round -gt $MaxRounds) {
        Write-BridgeLog "MaxRounds reached."
        break
    }

    try {
        Write-Status -State "calling-codex" -Round $round -Speaker "CODEX"
        Write-BridgeLog "Round ${round}: calling Codex."
        $codexPrompt = New-AgentPrompt -AgentName "CODEX" -OtherName "CLAUDE" -Messages $messages
        $codexReply = Invoke-CodexReply -Prompt $codexPrompt

        if ([string]::IsNullOrWhiteSpace($codexReply)) {
            throw "Codex returned an empty response."
        }

        $messages += [pscustomobject]@{ Speaker = "CODEX"; Text = $codexReply }
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Utf8Content -Path $CodexLogPath -Value "`n[$stamp] Round $round`n$codexReply`n"
        Add-Utf8Content -Path $TranscriptPath -Value "`n## CODEX round $round`n$codexReply`n"

        if (Test-Path -LiteralPath $StopPath) {
            Write-BridgeLog "Stop file detected after Codex round $round."
            break
        }

        Start-Sleep -Seconds $DelaySeconds

        Write-Status -State "calling-claude" -Round $round -Speaker "CLAUDE"
        Write-BridgeLog "Round ${round}: calling Claude."
        $claudePrompt = New-AgentPrompt -AgentName "CLAUDE" -OtherName "CODEX" -Messages $messages
        $claudeReply = Invoke-ClaudeReply -Prompt $claudePrompt

        if ([string]::IsNullOrWhiteSpace($claudeReply)) {
            throw "Claude returned an empty response."
        }

        $messages += [pscustomobject]@{ Speaker = "CLAUDE"; Text = $claudeReply }
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Utf8Content -Path $ClaudeLogPath -Value "`n[$stamp] Round $round`n$claudeReply`n"
        Add-Utf8Content -Path $TranscriptPath -Value "`n## CLAUDE round $round`n$claudeReply`n"

        Write-Status -State "sleeping" -Round $round
        Start-Sleep -Seconds $DelaySeconds
        $round++
    }
    catch {
        Write-BridgeLog "ERROR: $($_.Exception.Message)"
        Write-Status -State "error" -Round $round
        Add-Utf8Content -Path $TranscriptPath -Value "`n## ERROR round $round`n$($_.Exception.Message)`n"
        break
    }
}

Write-Status -State "stopped" -Round ($round - 1)
Write-BridgeLog "Bridge stopped."
