<#
.SYNOPSIS
  Phases 11-12 — put secret files (.env, SSH private keys, n8n config, credentials) into ONE AES-256
  encrypted 7-Zip archive (header encryption on, so file names are hidden too).
.DESCRIPTION
  MUST be run by the user in their own interactive terminal: 7-Zip prompts for the passphrase itself,
  so the passphrase never appears in arguments, scripts, logs or shell history.
  No plaintext staging copy is created. If 7-Zip is missing -> SECRET_BACKUP_BLOCKED.
  Claude Code sessions must NOT run this script — ask the user to run it.
.EXAMPLE
  pwsh -File .\08-Backup-Secrets-Encrypted.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration'
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [string]$DestinationRoot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase08-secrets.log'
$listSrc = Join-Path $ws.Manifests 'secret-files.txt'
if (-not (Test-Path -LiteralPath $listSrc)) { throw 'secret-files.txt not found — run 03-Discover-Config.ps1 first.' }

$sevenZip = @('7z', (Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')) |
    Where-Object { $_ -and ((Get-Command $_ -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $_)) } | Select-Object -First 1
if (-not $sevenZip) {
    Write-PhaseStatus -Workspace $ws -Phase 'phase08-secrets' -Status 'BLOCKED' -Details @('SECRET_BACKUP_BLOCKED: 7-Zip not installed. Install with: winget install --id 7zip.7zip -e, then re-run this script yourself.')
    throw 'SECRET_BACKUP_BLOCKED: 7-Zip not found. Install: winget install --id 7zip.7zip -e'
}
if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
    Write-PhaseStatus -Workspace $ws -Phase 'phase08-secrets' -Status 'BLOCKED' -Details @('Needs an interactive terminal for the passphrase prompt — run it yourself, not through an agent.')
    throw 'This script needs an interactive terminal (passphrase prompt). Please run it yourself in PowerShell.'
}

$files = @(Get-Content -LiteralPath $listSrc | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
$extra = @()
foreach ($p in @((Join-Path $env:USERPROFILE '.ssh\config'), (Join-Path $env:USERPROFILE '.ssh\known_hosts'))) { if (Test-Path -LiteralPath $p) { $extra += $p } }
$files = @($files + $extra | Select-Object -Unique)
if ($files.Count -eq 0) { Write-MigLog 'No secret files found — nothing to encrypt.' -Level WARN -LogFile $log; Write-PhaseStatus -Workspace $ws -Phase 'phase08-secrets' -Status 'NOT_APPLICABLE'; return }

$outDir = Join-Path $ws.Restore 'encrypted-secrets'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$archive = Join-Path $outDir ("secrets-{0}-{1}.7z" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$listFile = Join-Path $outDir 'archive-input-list.txt'   # paths only — no secret values
[System.IO.File]::WriteAllLines($listFile, $files, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Encrypting $($files.Count) secret files into:" -ForegroundColor Cyan
Write-Host "  $archive"
Write-Host 'Choose a strong passphrase and store it in your password manager NOW. Without it the archive is unrecoverable.' -ForegroundColor Yellow
Write-Host ''
# -p with no value => 7-Zip prompts (hidden input + confirmation). -mhe=on encrypts file names. -spf2 keeps full paths minus drive letter.
& $sevenZip a -t7z -mhe=on -mx=5 -p -spf2 -scsUTF-8 $archive "@$listFile"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archive)) {
    Write-PhaseStatus -Workspace $ws -Phase 'phase08-secrets' -Status 'FAIL' -Details @("7z exit $LASTEXITCODE")
    throw "7-Zip failed (exit $LASTEXITCODE)."
}

Write-Host ''
Write-Host 'Restore test: enter the SAME passphrase again to prove the archive can be opened.' -ForegroundColor Cyan
& $sevenZip t -p $archive
$tested = ($LASTEXITCODE -eq 0)

$copied = $false
if ($DestinationRoot) {
    $destDir = Join-Path $DestinationRoot '99_ENCRYPTED_SECRETS'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $dest = Join-Path $destDir (Split-Path $archive -Leaf)
    if (Test-Path -LiteralPath $dest) { Write-MigLog "Destination already has $dest — not overwriting." -Level WARN -LogFile $log }
    else {
        Copy-Item -LiteralPath $archive -Destination $dest
        $copied = ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash)
    }
}
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $(Split-Path $archive -Leaf)" -Encoding ASCII
$status = if ($tested -and ($copied -or -not $DestinationRoot)) { 'PASS' } elseif ($tested) { 'PARTIAL' } else { 'FAIL' }
Write-PhaseStatus -Workspace $ws -Phase 'phase08-secrets' -Status $status -Details @("files=$($files.Count)", "archive_test=$tested", "copied_to_destination=$copied", 'passphrase stored by user (not verifiable by script)') -EvidencePath $archive
Write-MigLog "Secret archive: $status (test=$tested, copied=$copied)" -Level $(if ($status -eq 'PASS') { 'OK' } else { 'WARN' }) -LogFile $log
Write-Host 'Reminder: Windows environment-variable VALUES and browser-saved passwords are not in this archive. Save any that cannot be re-issued (e.g. N8N_ENCRYPTION_KEY) in your password manager.' -ForegroundColor Yellow
