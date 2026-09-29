<#
.SYNOPSIS
  Phase 29 — restore projects from a verified backup into a working folder. NEVER overwrites:
  robocopy /XC /XN /XO copies only files that do not exist at the target. Safe to re-run.
.EXAMPLE
  pwsh -File .\restore-projects-windows.ps1 -BackupRoot 'D:\Backup\Mosses-AI-Migration' -TargetRoot "$env:USERPROFILE\Projects" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$BackupRoot,
    [string]$TargetRoot = (Join-Path $env:USERPROFILE 'Projects'),
    [switch]$IncludeArchive
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$logDir = Join-Path $env:USERPROFILE 'AI-RESTORE-LOGS'
New-Item -ItemType Directory -Force -Path $logDir, $TargetRoot | Out-Null
$sets = @('01_PROJECTS')
if ($IncludeArchive) { $sets += '16_ARCHIVE' }
foreach ($set in $sets) {
    $srcSet = Join-Path $BackupRoot $set
    if (-not (Test-Path -LiteralPath $srcSet)) { Write-Warning "missing $srcSet"; continue }
    foreach ($d in Get-ChildItem -LiteralPath $srcSet -Directory) {
        $dst = Join-Path $TargetRoot $(if ($set -eq '16_ARCHIVE') { "_archive\$($d.Name)" } else { $d.Name })
        $rcLog = Join-Path $logDir ("restore-{0}-{1}.log" -f $d.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $args2 = @($d.FullName, $dst, '/E', '/XC', '/XN', '/XO', '/XJ', '/R:1', '/W:2', '/COPY:DAT', '/DCOPY:T', '/NP', '/NFL', '/NDL', "/UNILOG:$rcLog")
        Assert-SafeRobocopyArgs -Arguments $args2
        if ($PSCmdlet.ShouldProcess($dst, "restore from $($d.FullName) (no overwrite)")) {
            & robocopy @args2 | Out-Null
            $code = $LASTEXITCODE
            Write-Host ("{0} -> {1}: exit {2} {3}" -f $d.Name, $dst, $code, $(if ($code -ge 8) { 'FAILED' } else { 'ok' })) -ForegroundColor $(if ($code -ge 8) { 'Red' } else { 'Green' })
        }
    }
}
Write-Host ''
Write-Host 'Local commits/stashes not on GitHub are also in 13_GIT\bundles (git clone <bundle> or git fetch <bundle>).'
Write-Host 'Secret files (.env, keys) are NOT restored here — extract them from 99_ENCRYPTED_SECRETS with: 7z x -p <archive> -o<temp dir>'
Write-Host 'Note: -spf2 archives store paths like Users\Admin\... — map them to the new locations manually; do not blindly extract over existing files.'
