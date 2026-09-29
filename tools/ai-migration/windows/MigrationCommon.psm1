# MigrationCommon.psm1 — shared helpers for the AI workstation migration toolkit.
# Safety contract (enforced here, relied on by every script):
#   * Never delete, move or overwrite source data.
#   * Never print secret VALUES — only names/locations.
#   * Robocopy is COPY-only; /MIR /PURGE /MOV /MOVE are rejected.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+ (7+ recommended for long paths).

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

# Regenerable directories skipped by copy AND hashing (must stay identical for both).
$script:DefaultExcludeDirs = @(
    'node_modules', '.venv', 'venv', '__pycache__', '.next', '.turbo',
    '.pytest_cache', '.mypy_cache', '.ruff_cache', '.parcel-cache'
)

# Files that must NOT go into the plain project backup — they go to the
# encrypted secret archive instead (08-Backup-Secrets-Encrypted.ps1).
$script:SecretFilePatterns = @(
    '.env', '.env.*', '.dev.vars', '*.pem', '*.key', '*.pfx', '*.p12',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    '.credentials.json', 'credentials.json', 'serviceAccountKey.json',
    'google-service-account.json', '*.secret', '.npmrc', '.pypirc', '.netrc'
)

# Directories whose whole content is treated as secret (e.g. ~/.claude/secrets/graphic-bot-token.txt):
# excluded from the plain copy/hash, collected into the encrypted archive by 03/08.
$script:SecretDirNames = @('secrets', '.secrets')

# Names that never count as secret even if they match a pattern above.
$script:SecretFileAllowList = @('.env.example', '.env.sample', '.env.template', '.dev.vars.example')

$script:SecretNameRegex = '(?i)(API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_?KEY|CREDENTIAL|AUTH|DATABASE_URL|DSN|WEBHOOK|ENCRYPTION_KEY|^OPENAI_|^ANTHROPIC_|^CLAUDE_|^GOOGLE_|^GEMINI_|^GITHUB_|^GH_|^CLOUDFLARE_|^CF_|^SUPABASE_|^N8N_|^TELEGRAM_|^LINE_|^FRICLAWD_|^VERCEL_|^NETLIFY_|^AWS_|^POSTGRES|^MYSQL_|^REDIS_|^SSH_|^TAILSCALE_)'

$script:ForbiddenRobocopyFlags = @('/MIR', '/PURGE', '/MOV', '/MOVE')

$script:WorkspaceSubdirs = @('00_REPORTS', '01_MANIFESTS', '02_LOGS', '03_SCRIPTS', '04_RESTORE', '05_CHECKSUMS', '00_REPORTS\status', '04_RESTORE\git-bundles', '04_RESTORE\databases', '04_RESTORE\portable-config')

function Get-DefaultExcludeDirs { return $script:DefaultExcludeDirs }
function Get-SecretFilePatterns { return $script:SecretFilePatterns }
function Get-SecretDirNames { return $script:SecretDirNames }

function Test-IsInSecretDir {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($seg in ($Path -split '[\\/]')) { if ($script:SecretDirNames -contains $seg) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Workspace, logging, status
# ---------------------------------------------------------------------------

function Get-MigrationWorkspace {
    param([string]$Root = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'))
    foreach ($sub in $script:WorkspaceSubdirs) {
        $p = Join-Path $Root $sub
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    return [pscustomobject]@{
        Root      = $Root
        Reports   = Join-Path $Root '00_REPORTS'
        Status    = Join-Path $Root '00_REPORTS\status'
        Manifests = Join-Path $Root '01_MANIFESTS'
        Logs      = Join-Path $Root '02_LOGS'
        Scripts   = Join-Path $Root '03_SCRIPTS'
        Restore   = Join-Path $Root '04_RESTORE'
        Checksums = Join-Path $Root '05_CHECKSUMS'
    }
}

function Write-MigLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO',
        [string]$LogFile
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 }
}

# Status values: PASS, PARTIAL, FAIL, BLOCKED, NOT_APPLICABLE, DONE
function Write-PhaseStatus {
    param(
        [Parameter(Mandatory)]$Workspace,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('PASS', 'PARTIAL', 'FAIL', 'BLOCKED', 'NOT_APPLICABLE', 'DONE')][string]$Status,
        [string[]]$Details = @(),
        [string]$EvidencePath
    )
    $obj = [ordered]@{
        phase     = $Phase
        status    = $Status
        details   = $Details
        evidence  = $EvidencePath
        host      = $env:COMPUTERNAME
        timestamp = (Get-Date).ToString('o')
    }
    $file = Join-Path $Workspace.Status ("{0}.json" -f $Phase)
    $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Safe helpers
# ---------------------------------------------------------------------------

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandVersion {
    # Runs "<cmd> <args>" and returns the first output line, or $null. Never throws.
    param([Parameter(Mandatory)][string]$Name, [string[]]$Arguments = @('--version'))
    if (-not (Test-CommandExists $Name)) { return $null }
    try {
        $out = & $Name @Arguments 2>&1 | Select-Object -First 1
        if ($null -eq $out) { return '(installed, no version output)' }
        return ($out.ToString().Trim())
    } catch { return '(installed, version probe failed)' }
}

function Invoke-GitRead {
    # Read-only git invocation: no optional locks (status won't rewrite the index),
    # safe.directory=* so repos owned by another SID are still readable.
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$Arguments)
    $out = & git -c safe.directory=* --no-optional-locks -C $Repo @Arguments 2>$null
    return $out
}

function Assert-SafeRobocopyArgs {
    param([Parameter(Mandatory)][string[]]$Arguments)
    foreach ($a in $Arguments) {
        $flag = ($a -split ':')[0].ToUpperInvariant()
        if ($script:ForbiddenRobocopyFlags -contains $flag) {
            throw "SAFETY STOP: forbidden robocopy flag '$a' (destructive sync is not allowed during migration)."
        }
    }
}

function Test-IsSecretFileName {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:SecretFileAllowList -contains $Name) { return $false }
    foreach ($p in $script:SecretFilePatterns) { if ($Name -like $p) { return $true } }
    return $false
}

function Test-IsSecretVariableName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -match $script:SecretNameRegex)
}

function Get-EnvFileVariableNames {
    # Returns ONLY variable names from a dotenv-style file. Values are never returned.
    param([Parameter(Mandatory)][string]$Path)
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_\.]*)\s*=') { $names.Add($Matches[1]) }
        }
    } catch { }
    return ($names | Select-Object -Unique)
}

function Protect-Text {
    # Masks anything that looks like a credential inside free text (e.g. CLI output).
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)((?:key|token|secret|password|passwd|pwd|auth)[\w\-]*\s*[=:]\s*)\S+', '$1<REDACTED>')
    $t = [regex]::Replace($t, '(?i)\b(gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9\-_]{8,}|xox[abprs]-[A-Za-z0-9\-]{8,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)', '<REDACTED>')
    $t = [regex]::Replace($t, '(?i)(https?://)[^/\s:@]+:[^/\s@]+@', '$1<REDACTED>@')
    return $t
}

function Protect-Argument {
    # For MCP args: mask values that look like tokens or key=value secrets.
    param([AllowNull()][string]$Arg)
    if ($null -eq $Arg) { return $null }
    if ($Arg -match '^[A-Za-z0-9_\-\.=+/]{32,}$' -and $Arg -notmatch '[\\/].*[\\/]') { return '<REDACTED>' }
    return (Protect-Text $Arg)
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function ConvertTo-MarkdownTable {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][string[]]$Columns)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('| ' + ($Columns -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($Columns | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Rows) {
        $cells = foreach ($c in $Columns) {
            $v = $r.$c
            if ($v -is [array]) { $v = $v -join ', ' }
            ("$v" -replace '\|', '\|' -replace "`r?`n", ' ')
        }
        [void]$sb.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    if ($Rows.Count -eq 0) { [void]$sb.AppendLine('| ' + (($Columns | ForEach-Object { '—' }) -join ' | ') + ' |') }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# File enumeration shared by copy verification and hashing
# ---------------------------------------------------------------------------

function Get-BackupFileList {
    # Enumerates files under $Root using the SAME exclusions as 06-Copy-ToDestination:
    # prunes excluded dir names, skips reparse points (robocopy /XJ), skips secret files.
    # Returns objects: RelativePath (forward slashes), FullName, Length, LastWriteUtc.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludeDirs = $script:DefaultExcludeDirs,
        [switch]$IncludeSecrets,
        [System.Collections.Generic.List[string]]$Errors
    )
    $rootInfo = New-Object System.IO.DirectoryInfo($Root)
    $rootLen = $rootInfo.FullName.TrimEnd('\').Length + 1
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push($rootInfo)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in $dir.EnumerateFiles()) {
                if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if (-not $IncludeSecrets -and (Test-IsSecretFileName $f.Name)) { continue }
                [pscustomobject]@{
                    RelativePath = $f.FullName.Substring($rootLen).Replace('\', '/')
                    FullName     = $f.FullName
                    Length       = $f.Length
                    LastWriteUtc = $f.LastWriteTimeUtc.ToString('o')
                }
            }
            foreach ($d in $dir.EnumerateDirectories()) {
                if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($ExcludeDirs -contains $d.Name) { continue }
                if (-not $IncludeSecrets -and ($script:SecretDirNames -contains $d.Name)) { continue }
                $stack.Push($d)
            }
        } catch {
            if ($null -ne $Errors) { $Errors.Add(("{0} :: {1}" -f $dir.FullName, $_.Exception.Message)) }
        }
    }
}

function Get-DirectorySizeBytes {
    param([Parameter(Mandatory)][string]$Path, [string[]]$ExcludeDirs = @())
    $sum = [long]0
    foreach ($f in (Get-BackupFileList -Root $Path -ExcludeDirs $ExcludeDirs -IncludeSecrets)) { $sum += $f.Length }
    return $sum
}

function Get-FreeSpaceBytes {
    # Works for local drives and UNC shares (\\host\share).
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('MigWin32.Disk' -as [type])) {
        Add-Type -Namespace MigWin32 -Name Disk -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);
'@
    }
    $free = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
    $target = $Path.TrimEnd('\') + '\'
    if ([MigWin32.Disk]::GetDiskFreeSpaceEx($target, [ref]$free, [ref]$total, [ref]$totalFree)) {
        return [pscustomobject]@{ FreeBytes = [long]$free; TotalBytes = [long]$total }
    }
    return $null
}

Export-ModuleMember -Function * -Variable DefaultExcludeDirs, SecretFilePatterns, SecretDirNames
