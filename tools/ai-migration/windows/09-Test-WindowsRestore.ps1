<#
.SYNOPSIS
  Phase 28 — non-destructive restore test. Run ON THE DESTINATION PC (friclawd) against the backup root.
  Checks git repos, bundles, local-only files, databases, config, reports. Writes WINDOWS-RESTORE-TEST.md.
  Nothing in the backup is modified (git runs with --no-optional-locks; bundles are cloned into a temp dir).
.EXAMPLE
  pwsh -File .\09-Test-WindowsRestore.ps1 -BackupRoot 'D:\Backup\Mosses-AI-Migration'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupRoot,
    [int]$SampleRepos = 0   # 0 = all repos
)
$ErrorActionPreference = 'Continue'
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check { param($Area, $Item, $Status, $Evidence) $checks.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Evidence = $Evidence }) }
function Test-Exists { param($Area, $Rel) $p = Join-Path $BackupRoot $Rel; if (Test-Path -LiteralPath $p) { Add-Check $Area $Rel 'PASS' 'present' } else { Add-Check $Area $Rel 'FAIL' 'missing' } }

$git = [bool](Get-Command git -ErrorAction SilentlyContinue)
if (-not $git) { Add-Check 'Tooling' 'git' 'BLOCKED' 'git not installed on this PC — run bootstrap-windows.ps1 first' }

# 1. Integrity against SHA256SUMS (delegated)
$sums = Join-Path $BackupRoot '00_MANIFEST\SHA256SUMS.txt'
if (Test-Path -LiteralPath $sums) {
    & (Join-Path $PSScriptRoot 'Test-Sha256Sums.ps1') -Root $BackupRoot | Out-Host
    Add-Check 'Integrity' 'SHA256SUMS' $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) "Test-Sha256Sums exit $LASTEXITCODE (see 18_REPORTS\VERIFY-*.md)"
} else { Add-Check 'Integrity' 'SHA256SUMS' 'FAIL' 'SHA256SUMS.txt missing' }

# 2. Project inventory drives the expectations
$inv = Join-Path $BackupRoot '00_MANIFEST\AI-MIGRATION-WORK\01_MANIFESTS\PROJECT-INVENTORY.csv'
$plan = Join-Path $BackupRoot '00_MANIFEST\AI-MIGRATION-WORK\01_MANIFESTS\copy-plan.json'
if ((Test-Path $inv) -and (Test-Path $plan) -and $git) {
    $projects = @(Import-Csv $inv | Where-Object { $_.'Git?' -eq 'True' })
    $items = @((Get-Content $plan -Raw | ConvertFrom-Json).items | Where-Object { $_.Name -notlike 'workspace:*' })
    if ($SampleRepos -gt 0) { $projects = @($projects | Select-Object -First $SampleRepos) }
    foreach ($p in $projects) {
        $src = $p.'Absolute Path'
        $it = $items | Where-Object { $src -eq $_.Source -or $src.StartsWith($_.Source.TrimEnd('\') + '\') } | Sort-Object { $_.Source.Length } -Descending | Select-Object -First 1
        if (-not $it) { Add-Check 'Git' $src 'FAIL' 'repo not covered by any copied source (check migration-sources.json)'; continue }
        $restored = Join-Path $BackupRoot ($it.RelDest + $src.Substring($it.Source.TrimEnd('\').Length))
        if (-not (Test-Path -LiteralPath (Join-Path $restored '.git'))) { Add-Check 'Git' $src 'FAIL' "no .git at $restored"; continue }
        $g = @('-c', 'safe.directory=*', '--no-optional-locks', '-C', $restored)
        & git @g fsck --no-dangling --connectivity-only 2>$null | Out-Null
        $fsck = $LASTEXITCODE
        $head = (& git @g rev-parse HEAD 2>$null) -join ''
        $branch = (& git @g rev-parse --abbrev-ref HEAD 2>$null) -join ''
        $ev = "fsck=$fsck head=$(if ($head -eq $p.'HEAD Commit') { 'match' } else { "DIFF($head)" }) branch=$branch"
        $st = if ($fsck -eq 0 -and $head -eq $p.'HEAD Commit' -and $branch -eq $p.'Current Branch') { 'PASS' } else { 'FAIL' }
        # Local-only data: ignored/untracked files expected in the copy (secret files are intentionally absent).
        if ([int]("0" + $p.'Untracked Files?') -gt 0 -or [int]("0" + $p.'Ignored Local Files') -gt 0) {
            $un = @(& git @g status --porcelain=v1 2>$null | Where-Object { $_ -like '`?`?*' }).Count
            $ev += " untracked_now=$un expected=$($p.'Untracked Files?')"
            if ($un -lt [int]("0" + $p.'Untracked Files?')) { $st = 'PARTIAL' }
        }
        Add-Check 'Git' $src $st $ev
    }
} else { Add-Check 'Git' 'repositories' 'BLOCKED' 'PROJECT-INVENTORY.csv / copy-plan.json missing in backup, or git missing' }

# 3. Bundles: clone each into a temp dir (proves local commits/stashes are recoverable without the notebook)
$bundles = @(Get-ChildItem -LiteralPath (Join-Path $BackupRoot '13_GIT\bundles') -Filter '*.bundle' -ErrorAction SilentlyContinue)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("restore-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
foreach ($b in $bundles) {
    if (-not $git) { break }
    $dst = Join-Path $tmp $b.BaseName
    & git clone --quiet --mirror $b.FullName $dst 2>$null
    $refs = if ($LASTEXITCODE -eq 0) { @(& git -C $dst for-each-ref 2>$null).Count } else { 0 }
    Add-Check 'Git bundle' $b.Name $(if ($refs -gt 0) { 'PASS' } else { 'FAIL' }) "refs=$refs (cloned to temp)"
}
if ($bundles.Count -eq 0) { Add-Check 'Git bundle' '13_GIT\bundles' 'NOT_APPLICABLE' 'no bundles (all repos matched their remotes?)' }

# 4. Databases
foreach ($db in @(Get-ChildItem -LiteralPath (Join-Path $BackupRoot '11_DATABASES') -Recurse -File -ErrorAction SilentlyContinue)) {
    if (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
        $r = (& sqlite3 "file:$($db.FullName -replace '\\','/')?mode=ro" 'PRAGMA integrity_check;' 2>&1) -join ' '
        Add-Check 'Database' $db.Name $(if ($r -eq 'ok') { 'PASS' } else { 'FAIL' }) "integrity_check=$r"
    } else { Add-Check 'Database' $db.Name 'BLOCKED' 'sqlite3 not installed on this PC' }
}

# 5. Config, AI assets, secrets archive, reports
foreach ($rel in '07_CLAUDE', '14_CONFIG\portable-config', '99_ENCRYPTED_SECRETS', '18_REPORTS\MCP-INVENTORY.md', '18_REPORTS\SKILLS-MANIFEST.md',
    '18_REPORTS\AGENTS-MANIFEST.md', '18_REPORTS\PROMPTS-MANIFEST.md', '18_REPORTS\AI-BRAIN-MAP.md', '18_REPORTS\SECRET-DEPENDENCY-MAP.md',
    '18_REPORTS\GIT-SSH-INVENTORY.md', '18_REPORTS\N8N-MIGRATION.md', '18_REPORTS\software-manifest.md') { Test-Exists 'Assets' $rel }
$sk = @(Get-ChildItem -LiteralPath (Join-Path $BackupRoot '07_CLAUDE') -Recurse -Filter 'SKILL.md' -ErrorAction SilentlyContinue).Count
Add-Check 'Assets' 'Claude skills (SKILL.md in 07_CLAUDE)' $(if ($sk -gt 0) { 'PASS' } else { 'PARTIAL' }) "count=$sk"
$enc = @(Get-ChildItem -LiteralPath (Join-Path $BackupRoot '99_ENCRYPTED_SECRETS') -Filter '*.7z' -ErrorAction SilentlyContinue)
Add-Check 'Secrets' 'encrypted archive present' $(if ($enc.Count) { 'PASS' } else { 'FAIL' }) $(if ($enc.Count) { ($enc.Name -join ', ') + ' — open-test with: 7z t -p <archive>' } else { 'run 08-Backup-Secrets-Encrypted.ps1' })
$n8n = Join-Path $BackupRoot '08_N8N'
if (Test-Path -LiteralPath $n8n) { Add-Check 'n8n' 'n8n data copied' 'PASS' 'encryptionKey file must be in the encrypted archive' } else { Add-Check 'n8n' '08_N8N' 'NOT_APPLICABLE' 'no local n8n data copied' }

if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }   # temp clones only, never backup data

$fail = @($checks | Where-Object { $_.Status -in 'FAIL', 'BLOCKED' }).Count
$part = @($checks | Where-Object { $_.Status -eq 'PARTIAL' }).Count
$overall = if ($fail) { 'FAIL' } elseif ($part) { 'PARTIAL' } else { 'PASS' }
$md = "# WINDOWS RESTORE TEST — $env:COMPUTERNAME`n`nBackup root: ``$BackupRoot``  Date: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))`n`n**Overall: $overall** (fail/blocked=$fail partial=$part)`n`n| Area | Item | Status | Evidence |`n|---|---|---|---|`n" +
    (($checks | ForEach-Object { "| $($_.Area) | $($_.Item) | $($_.Status) | $($_.Evidence -replace '\|','/') |" }) -join "`n")
$repDir = Join-Path $BackupRoot '18_REPORTS'
New-Item -ItemType Directory -Force -Path $repDir | Out-Null
Set-Content -LiteralPath (Join-Path $repDir 'WINDOWS-RESTORE-TEST.md') -Value $md -Encoding UTF8
[ordered]@{ phase = 'phase28-windows-restore'; status = $overall; host = $env:COMPUTERNAME; timestamp = (Get-Date).ToString('o'); details = @("fail=$fail", "partial=$part", "checks=$($checks.Count)") } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repDir 'WINDOWS-RESTORE-TEST.json') -Encoding UTF8
Write-Host "Windows restore test: $overall — report: $repDir\WINDOWS-RESTORE-TEST.md"
