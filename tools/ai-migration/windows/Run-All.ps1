<#
.SYNOPSIS
  One-shot runner: discovery -> local backups -> copy to friclawd -> SHA-256 verify -> encrypted secrets
  -> final report / Hard Gate. Non-destructive; stops at the first critical failure.
.DESCRIPTION
  Pauses only for:
    1. confirming the list of folders to copy (skip with -AutoApproveSources)
    2. the 7-Zip passphrase (secret archive) — must be typed by you
  Never resets, deletes or uninstalls anything. Run it yourself in a normal (non-admin) PowerShell window.
.EXAMPLE
  pwsh -File .\Run-All.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration'
.EXAMPLE
  pwsh -File .\Run-All.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration' -DryRun   # plan only, copies nothing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestinationRoot,
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [switch]$AutoApproveSources,
    [switch]$SkipSecrets,
    [switch]$ExportBrainD1,
    [switch]$Resume,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$transcript = Join-Path $ws.Logs ("run-all-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -LiteralPath $transcript -Append | Out-Null

$summary = New-Object System.Collections.Generic.List[object]
$runFailed = $false
function Invoke-Step {
    # Runs a toolkit script in-process. A script's `exit N` returns here as $LASTEXITCODE; a throw is caught.
    param([string]$Name, [string]$Script, [hashtable]$Params = @{}, [switch]$Critical)
    Write-Host ''
    Write-Host ("=== {0} ===" -f $Name) -ForegroundColor Cyan
    $start = Get-Date
    $global:LASTEXITCODE = 0
    $ok = $true; $msg = ''
    try {
        & (Join-Path $PSScriptRoot $Script) @Params
        if ($LASTEXITCODE -ne 0) { $ok = $false; $msg = "exit code $LASTEXITCODE" }
    } catch { $ok = $false; $msg = $_.Exception.Message }
    $summary.Add([pscustomobject]@{ Step = $Name; Result = if ($ok) { 'OK' } else { 'FAILED' }; Detail = $msg; Minutes = [math]::Round(((Get-Date) - $start).TotalMinutes, 1) })
    if (-not $ok) {
        Write-Host ("{0} FAILED: {1}" -f $Name, $msg) -ForegroundColor Red
        if ($Critical) { throw "STOP: critical step '$Name' failed — nothing after it was run. See $transcript" }
    }
    return $ok
}
function Show-Summary {
    Write-Host ''
    Write-Host '=== RUN-ALL SUMMARY ===' -ForegroundColor Cyan
    $summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "Full log: $transcript"
}

try {
    Write-Host 'AI migration — one-shot run (copy only, nothing is deleted or reset)' -ForegroundColor Green
    Write-Host "Destination: $DestinationRoot   DryRun: $DryRun"

    # --- Preflight: destination reachable before spending time on discovery ---
    if ($DestinationRoot -match '^\\\\([^\\]+)\\([^\\]+)') {
        $share = "\\$($Matches[1])\$($Matches[2])"
        if (-not (Test-Path -LiteralPath $share)) { throw "Destination share not reachable: $share — check Tailscale and the share name/permissions on friclawd." }
        Write-MigLog "Destination share reachable: $share" -Level OK
    }

    # --- 1. Discovery ---
    Invoke-Step 'Phase 0  session'  '00-Start-MigrationSession.ps1' @{ WorkspaceRoot = $WorkspaceRoot } -Critical | Out-Null
    Invoke-Step 'Phase 1  machine'  '01-Discover-Machine.ps1'       @{ WorkspaceRoot = $WorkspaceRoot } | Out-Null
    Invoke-Step 'Phase 2  projects' '02-Discover-Projects.ps1'      @{ WorkspaceRoot = $WorkspaceRoot } -Critical | Out-Null
    Invoke-Step 'Phase 3  config'   '03-Discover-Config.ps1'        @{ WorkspaceRoot = $WorkspaceRoot } -Critical | Out-Null
    Invoke-Step 'Phase 4  services' '04-Discover-Services.ps1'      @{ WorkspaceRoot = $WorkspaceRoot } | Out-Null
    Invoke-Step 'Cloudflare plan'   '11-Plan-CloudflareMigration.ps1' @{ WorkspaceRoot = $WorkspaceRoot } | Out-Null

    # --- 2. Confirm copy sources (the one decision that needs a human) ---
    $srcFile = Join-Path $ws.Manifests 'migration-sources.json'
    $cfg = Get-Content -LiteralPath $srcFile -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host '=== Folders to copy (include=True) and skipped (include=False) ===' -ForegroundColor Cyan
    $cfg.sources | Select-Object include, size, path, destination, reason | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $unknown = @(Select-String -LiteralPath (Join-Path $ws.Reports 'AI-BRAIN-MAP.md') -Pattern 'NOT INSIDE A DETECTED PROJECT' -ErrorAction SilentlyContinue).Count
    if ($unknown) { Write-Host "Note: $unknown AI-related paths are outside detected projects — see 00_REPORTS\AI-BRAIN-MAP.md. Add them to migration-sources.json if they matter." -ForegroundColor Yellow }
    if (-not $AutoApproveSources) {
        Write-Host "To change the list: edit $srcFile, save, then answer." -ForegroundColor Yellow
        $answer = Read-Host 'Copy the folders marked include=True? (y = yes / n = stop here)'
        if ($answer -notmatch '^(y|yes)$') {
            $summary.Add([pscustomobject]@{ Step = 'Confirm sources'; Result = 'STOPPED BY USER'; Detail = 'no copy performed'; Minutes = 0 })
            Show-Summary; return
        }
    }

    # --- 3. Local backup artifacts ---
    $p5 = @{ WorkspaceRoot = $WorkspaceRoot }
    if ($ExportBrainD1) { $p5.ExportBrainD1 = $true }
    Invoke-Step 'Phase 5  local backups (git bundles, SQLite, config)' '05-Prepare-LocalBackups.ps1' $p5 -Critical | Out-Null

    # --- 4. Copy ---
    $p6 = @{ DestinationRoot = $DestinationRoot; WorkspaceRoot = $WorkspaceRoot }
    if ($Resume) { $p6.Resume = $true }
    if ($DryRun) { $p6.DryRun = $true }
    Invoke-Step $(if ($DryRun) { 'Phase 6  copy (DRY RUN)' } else { 'Phase 6  copy to friclawd' }) '06-Copy-ToDestination.ps1' $p6 -Critical | Out-Null
    if ($DryRun) {
        Write-Host 'Dry run finished — nothing was copied. See 00_REPORTS\COPY-REPORT.md, then run again without -DryRun.' -ForegroundColor Yellow
        Show-Summary; return
    }

    # --- 5. Verify ---
    Invoke-Step 'Phase 7  SHA-256 manifest + verify destination' '07-New-HashManifest.ps1' @{ WorkspaceRoot = $WorkspaceRoot; VerifyDestination = $true } | Out-Null

    # --- 6. Secrets (interactive passphrase) ---
    if ($SkipSecrets) {
        $summary.Add([pscustomobject]@{ Step = 'Phase 8  secrets'; Result = 'SKIPPED'; Detail = '-SkipSecrets'; Minutes = 0 })
    } elseif ([Console]::IsInputRedirected) {
        $summary.Add([pscustomobject]@{ Step = 'Phase 8  secrets'; Result = 'SKIPPED'; Detail = 'no interactive console — run 08-Backup-Secrets-Encrypted.ps1 yourself'; Minutes = 0 })
    } else {
        Invoke-Step 'Phase 8  encrypted secrets (type your passphrase)' '08-Backup-Secrets-Encrypted.ps1' @{ WorkspaceRoot = $WorkspaceRoot; DestinationRoot = $DestinationRoot } | Out-Null
    }

    # --- 7. Final report / Hard Gate ---
    Invoke-Step 'Final report + Hard Gate' '10-New-FinalReport.ps1' @{ WorkspaceRoot = $WorkspaceRoot; FirstBackupRoot = $DestinationRoot } | Out-Null
    Show-Summary
    Write-Host ''
    Write-Host 'Next: on friclawd run 09-Test-WindowsRestore.ps1 -BackupRoot <local path of the backup>; on the Mac run macos/pull-backup-from-smb.sh.' -ForegroundColor Yellow
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Show-Summary
    $runFailed = $true
} finally {
    Stop-Transcript | Out-Null
}
if ($runFailed) { exit 1 }
