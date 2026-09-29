<#
.SYNOPSIS
  Phases 41-43, 46 — aggregate evidence into AI-MIGRATION-FINAL-REPORT.md and print the HARD SAFETY GATE.
.DESCRIPTION
  SAFE_TO_WIPE is computed from evidence files only:
    * workspace status JSON written by scripts 00-08
    * <FirstBackupRoot>\18_REPORTS\VERIFY-*.json and WINDOWS-RESTORE-TEST.json (written on friclawd)
    * 00_REPORTS\attestations.json for evidence produced on other machines (Mac, Brain restore, BitLocker).
      Each attestation must name an evidence file; the script checks that file exists.
  This script never deletes anything and never starts a reset.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [string]$FirstBackupRoot
)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot

function Get-Status { param($Phase) $f = Join-Path $ws.Status "$Phase.json"; if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } return $null }
function Get-Latest { param($Dir, $Filter) Get-ChildItem -LiteralPath $Dir -Filter $Filter -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

$attFile = Join-Path $ws.Reports 'attestations.json'
$att = @{}
if (Test-Path -LiteralPath $attFile) {
    foreach ($a in @(Get-Content -LiteralPath $attFile -Raw | ConvertFrom-Json)) {
        $evOk = $a.evidence -and (Test-Path -LiteralPath $a.evidence)
        $att[$a.milestone] = [pscustomobject]@{ Status = if ($evOk) { $a.status } else { 'UNVERIFIED (evidence file missing)' }; Evidence = $a.evidence; Note = $a.note }
    }
}
function Get-Att { param($Name) if ($att.ContainsKey($Name)) { return $att[$Name] } return [pscustomobject]@{ Status = 'NOT_DONE'; Evidence = ''; Note = '' } }

$m = [ordered]@{}
$disc = @('phase00-session', 'phase01-machine', 'phase02-projects', 'phase03-config', 'phase04-services') | ForEach-Object { Get-Status $_ }
$m['DISCOVERY_COMPLETE'] = if (@($disc | Where-Object { $null -eq $_ -or $_.status -ne 'DONE' }).Count -eq 0) { 'PASS' } else { 'NOT_DONE' }

$copy = Get-Status 'phase06-copy'
$verifyFirst = $null; $winRestore = $null
if ($FirstBackupRoot) {
    $vf = Get-Latest (Join-Path $FirstBackupRoot '18_REPORTS') 'VERIFY-*.json'
    if ($vf) { $verifyFirst = Get-Content -LiteralPath $vf.FullName -Raw | ConvertFrom-Json }
    $wr = Join-Path $FirstBackupRoot '18_REPORTS\WINDOWS-RESTORE-TEST.json'
    if (Test-Path -LiteralPath $wr) { $winRestore = Get-Content -LiteralPath $wr -Raw | ConvertFrom-Json }
}
if (-not $verifyFirst) { $verifyFirst = Get-Status 'phase27-verify-first-destination' }
$m['FIRST_BACKUP_VERIFIED'] = if ($copy -and $copy.status -eq 'PASS' -and $verifyFirst -and $verifyFirst.status -eq 'PASS') { 'PASS' } elseif ($copy) { 'FAIL' } else { 'NOT_DONE' }
$m['WINDOWS_RESTORE_VERIFIED'] = if ($winRestore) { $winRestore.status } else { 'NOT_DONE' }
$m['SECOND_BACKUP_VERIFIED'] = (Get-Att 'SECOND_BACKUP_VERIFIED').Status
$m['MACOS_RESTORE_VERIFIED'] = (Get-Att 'MACOS_RESTORE_VERIFIED').Status
$m['BRAIN_RESTORE_VERIFIED'] = (Get-Att 'BRAIN_RESTORE_VERIFIED').Status
$sec = Get-Status 'phase08-secrets'
$m['SECRET_BACKUP'] = if ($sec) { $sec.status } else { 'NOT_DONE' }
$lb = Get-Status 'phase05-local-backups'
$m['GIT_LOCAL_STATE_PRESERVED'] = if ($lb) { $lb.status } else { 'NOT_DONE' }
$m['BITLOCKER_RECOVERY_CONFIRMED'] = (Get-Att 'BITLOCKER_RECOVERY_CONFIRMED').Status
$m['CRITICAL_UNKNOWNS_RESOLVED'] = (Get-Att 'CRITICAL_UNKNOWNS_RESOLVED').Status

$required = @('DISCOVERY_COMPLETE', 'FIRST_BACKUP_VERIFIED', 'WINDOWS_RESTORE_VERIFIED', 'SECOND_BACKUP_VERIFIED', 'MACOS_RESTORE_VERIFIED', 'BRAIN_RESTORE_VERIFIED', 'SECRET_BACKUP', 'GIT_LOCAL_STATE_PRESERVED', 'BITLOCKER_RECOVERY_CONFIRMED', 'CRITICAL_UNKNOWNS_RESOLVED')
$notPass = @($required | Where-Object { $m[$_] -ne 'PASS' -and $m[$_] -ne 'NOT_APPLICABLE' })
$envReady = if ($m['WINDOWS_RESTORE_VERIFIED'] -eq 'PASS' -and $m['MACOS_RESTORE_VERIFIED'] -in 'PASS', 'NOT_APPLICABLE') { 'ENVIRONMENT_RESTORE_READY' } else { 'ENVIRONMENT_RESTORE_NOT_READY' }
$decision = if ($notPass.Count -eq 0) { 'SAFE_TO_WIPE' } else { 'NOT_SAFE_TO_WIPE' }

$reportList = Get-ChildItem -LiteralPath $ws.Reports -Filter '*.md' | ForEach-Object { "- $($_.Name)" }
$rows = foreach ($k in $m.Keys) { [pscustomobject]@{ Milestone = $k; Status = $m[$k]; Evidence = if ($att.ContainsKey($k)) { $att[$k].Evidence } else { '' } } }
$md = @"
# AI MIGRATION FINAL REPORT

Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm')) on $($env:COMPUTERNAME)

## 1. Executive summary

- Decision: **$decision**
- Environment: **$envReady**
- Blocking items: $(if ($notPass) { ($notPass | ForEach-Object { "$_ = $($m[$_])" }) -join '; ' } else { 'none' })

## Milestones

$(ConvertTo-MarkdownTable -Rows @($rows) -Columns Milestone, Status, Evidence)

## First backup (friclawd)

- Copy: $(if ($copy) { "$($copy.status) — $($copy.details -join ', ')" } else { 'not run' })
- SHA-256: $(if ($verifyFirst) { "$($verifyFirst.status) — $($verifyFirst.details -join ', ')" } else { 'not run' })
- Restore test: $(if ($winRestore) { "$($winRestore.status) — $($winRestore.details -join ', ')" } else { 'not run' })

## Detailed sections

Sections 2-38 of the required report are the individual reports in this folder:

$($reportList -join "`n")

## Reauthentication required on every destination

Claude Code / Claude Desktop, GitHub (gh auth login), Google, Microsoft, Cloudflare (wrangler login), Supabase, Tailscale, n8n owner login, VS Code / Cursor accounts.

## Safe-to-wipe decision

**$decision**. SAFE_TO_WIPE requires every milestone above to be PASS (or NOT_APPLICABLE) with evidence.
"@
$out = Join-Path $ws.Reports 'AI-MIGRATION-FINAL-REPORT.md'
Set-Content -LiteralPath $out -Value $md -Encoding UTF8
if ($FirstBackupRoot -and (Test-Path -LiteralPath (Join-Path $FirstBackupRoot '18_REPORTS'))) { Copy-Item -LiteralPath $out -Destination (Join-Path $FirstBackupRoot '18_REPORTS\AI-MIGRATION-FINAL-REPORT.md') -Force }

$gate = @"

================ HARD SAFETY GATE ================
CRITICAL DATA STATUS   : $($m['GIT_LOCAL_STATE_PRESERVED'])
FRICLAWD STATUS        : backup=$($m['FIRST_BACKUP_VERIFIED']) restore=$($m['WINDOWS_RESTORE_VERIFIED'])
MAC STATUS             : backup=$($m['SECOND_BACKUP_VERIFIED']) restore=$($m['MACOS_RESTORE_VERIFIED'])
VPS STATUS             : $((Get-Att 'VPS_BACKUP_VERIFIED').Status) (optional)
BRAIN STATUS           : $($m['BRAIN_RESTORE_VERIFIED'])
MCP / SKILLS STATUS    : $($m['DISCOVERY_COMPLETE']) (inventories)
SECRET BACKUP STATUS   : $($m['SECRET_BACKUP'])
BITLOCKER STATUS       : $($m['BITLOCKER_RECOVERY_CONFIRMED'])
UNKNOWNS RESOLVED      : $($m['CRITICAL_UNKNOWNS_RESOLVED'])
DECISION               : $decision
==================================================
Waiting for:
AUTHORIZE_FINAL_CLEANUP_AND_RESET
"@
Write-Host $gate -ForegroundColor $(if ($decision -eq 'SAFE_TO_WIPE') { 'Green' } else { 'Yellow' })
Write-Host "Report: $out"
