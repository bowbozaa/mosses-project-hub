<#
.SYNOPSIS
  Phases 26-27 — build SHA256SUMS.txt + BACKUP-MANIFEST.csv from the SOURCE, using exactly the copy plan
  written by 06 (same sources, same exclusions), then optionally verify the destination.
.DESCRIPTION
  SHA256SUMS.txt uses the coreutils format "<hash>  <relative/path>" with paths relative to the backup root,
  so it can be checked on Windows (Test-Sha256Sums.ps1) and macOS (shasum -a 256 -c).
  Volatile items (workspace/report copies) are listed in the manifest but not hashed.
.EXAMPLE
  pwsh -File .\07-New-HashManifest.ps1 -VerifyDestination
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [switch]$VerifyDestination
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase07-hash.log'
$planFile = Join-Path $ws.Manifests 'copy-plan.json'
if (-not (Test-Path -LiteralPath $planFile)) { throw 'copy-plan.json not found — run 06-Copy-ToDestination.ps1 first.' }
$plan = Get-Content -LiteralPath $planFile -Raw | ConvertFrom-Json
$volatile = @('workspace:00_MANIFEST\AI-MIGRATION-WORK', 'workspace:18_REPORTS')

$sumsPath = Join-Path $ws.Checksums 'SHA256SUMS.txt'
$manifestPath = Join-Path $ws.Checksums 'BACKUP-MANIFEST.csv'
$sums = New-Object System.Text.StringBuilder
$manifest = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
$totalFiles = 0; $totalBytes = [long]0

foreach ($item in $plan.items) {
    if ($volatile -contains $item.Name) { Write-MigLog "Skipping volatile item $($item.Name)" -LogFile $log; continue }
    if (-not (Test-Path -LiteralPath $item.Source)) { $errors.Add("source missing: $($item.Source)"); continue }
    $xd = @($plan.excludeDirs) + @($item.ExtraExcludeDirs)
    $prefix = ($item.RelDest -replace '\\', '/').TrimEnd('/')
    $classification = switch -Regex ($item.RelDest) {
        '^01_PROJECTS' { 'PROJECT'; break } '^16_ARCHIVE' { 'ARCHIVE'; break } '^13_GIT' { 'GIT_BUNDLE'; break }
        '^11_DATABASES' { 'DATABASE'; break } '^07_CLAUDE' { 'CLAUDE'; break } '^14_CONFIG' { 'CONFIG'; break }
        '^02_AI_BRAIN' { 'AI_BRAIN'; break } default { 'OTHER' }
    }
    Write-MigLog "Hashing $($item.Source)" -LogFile $log
    $n = 0
    foreach ($f in (Get-BackupFileList -Root $item.Source -ExcludeDirs $xd -Errors $errors)) {
        try {
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        } catch { $errors.Add("hash failed: $($f.FullName) :: $($_.Exception.Message)"); continue }
        $rel = "$prefix/$($f.RelativePath)"
        [void]$sums.Append($h).Append('  ').Append($rel).Append("`n")
        $manifest.Add([pscustomobject]@{ RelativePath = $rel; Size = $f.Length; LastWriteUtc = $f.LastWriteUtc; Classification = $classification; Source = $f.FullName; SHA256 = $h })
        $totalFiles++; $totalBytes += $f.Length; $n++
        if ($n % 5000 -eq 0) { Write-MigLog "  ... $n files" -LogFile $log }
    }
}
# LF line endings, no BOM — required by `shasum -c` on macOS.
[System.IO.File]::WriteAllText($sumsPath, $sums.ToString(), (New-Object System.Text.UTF8Encoding($false)))
$manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
if ($errors.Count) { $errors | Set-Content -LiteralPath (Join-Path $ws.Logs 'phase07-hash-errors.log') -Encoding UTF8 }
Write-MigLog ("Source manifest: {0} files, {1}, {2} errors" -f $totalFiles, (Format-Bytes $totalBytes), $errors.Count) -Level $(if ($errors.Count) { 'WARN' } else { 'OK' }) -LogFile $log

$destRoot = $plan.destinationRoot
if (Test-Path -LiteralPath (Join-Path $destRoot '00_MANIFEST')) {
    Copy-Item -LiteralPath $sumsPath -Destination (Join-Path $destRoot '00_MANIFEST\SHA256SUMS.txt') -Force
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $destRoot '00_MANIFEST\BACKUP-MANIFEST.csv') -Force
    Write-MigLog "Copied SHA256SUMS.txt + BACKUP-MANIFEST.csv to $destRoot\00_MANIFEST" -Level OK -LogFile $log
}
$status = if ($errors.Count) { 'PARTIAL' } else { 'PASS' }
Write-PhaseStatus -Workspace $ws -Phase 'phase07-source-manifest' -Status $status -Details @("files=$totalFiles", "bytes=$totalBytes", "errors=$($errors.Count)") -EvidencePath $sumsPath

if ($VerifyDestination) {
    & (Join-Path $PSScriptRoot 'Test-Sha256Sums.ps1') -Root $destRoot -SumsFile $sumsPath -ManifestFile $manifestPath -StatusFile (Join-Path $ws.Status 'phase27-verify-first-destination.json')
    exit $LASTEXITCODE
}
if ($status -ne 'PASS') { exit 1 }
