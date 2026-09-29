<#
.SYNOPSIS
  Phase 27/36 — verify a backup copy against SHA256SUMS.txt. Read-only. Runs on Windows PowerShell 5.1,
  PowerShell 7 on Windows, and pwsh on macOS/Linux.
.OUTPUTS
  <Root>/18_REPORTS/VERIFY-<host>-<timestamp>.md (+ .json). Exit code 0 = all verified, 1 = problems.
.EXAMPLE
  pwsh -File ./Test-Sha256Sums.ps1 -Root '\\100.127.194.73\Backup\Mosses-AI-Migration'
  pwsh -File ./Test-Sha256Sums.ps1 -Root ~/Mosses-AI-Migration
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$SumsFile,
    [string]$ManifestFile,
    [string]$StatusFile,
    [switch]$NoReport
)
$ErrorActionPreference = 'Stop'
if (-not $SumsFile) { $SumsFile = Join-Path (Join-Path $Root '00_MANIFEST') 'SHA256SUMS.txt' }
if (-not $ManifestFile) { $ManifestFile = Join-Path (Join-Path $Root '00_MANIFEST') 'BACKUP-MANIFEST.csv' }
if (-not (Test-Path -LiteralPath $SumsFile)) { throw "SHA256SUMS not found: $SumsFile" }

$expectedBytes = $null
if (Test-Path -LiteralPath $ManifestFile) { $expectedBytes = (Import-Csv -LiteralPath $ManifestFile | Measure-Object -Property Size -Sum).Sum }

$expected = 0; $ok = 0; $missing = New-Object System.Collections.Generic.List[string]; $bad = New-Object System.Collections.Generic.List[string]
$copiedBytes = [long]0
$hostName = [System.Net.Dns]::GetHostName()
foreach ($line in [System.IO.File]::ReadLines($SumsFile)) {
    if (-not $line) { continue }
    $hash = $line.Substring(0, 64); $rel = $line.Substring(66)
    $expected++
    $parts = $rel -split '/'
    $path = $Root
    foreach ($p in $parts) { $path = Join-Path $path $p }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing.Add($rel); continue }
    try {
        $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $copiedBytes += (New-Object System.IO.FileInfo($path)).Length
        if ($h -eq $hash) { $ok++ } else { $bad.Add($rel) }
    } catch { $bad.Add("$rel (read error: $($_.Exception.Message))") }
    if ($expected % 5000 -eq 0) { Write-Host "  ... $expected checked" }
}
$status = if ($missing.Count -eq 0 -and $bad.Count -eq 0 -and $expected -gt 0) { 'PASS' } elseif ($ok -gt 0) { 'PARTIAL' } else { 'FAIL' }
$summary = [ordered]@{
    phase = 'phase27-verify'; status = $status; host = $hostName; root = $Root; timestamp = (Get-Date).ToString('o')
    expectedFiles = $expected; hashVerified = $ok; hashFailed = $bad.Count; missing = $missing.Count
    expectedBytes = $expectedBytes; copiedBytes = $copiedBytes
    details = @("expected=$expected", "verified=$ok", "failed=$($bad.Count)", "missing=$($missing.Count)")
}
Write-Host ("SHA-256 verification on {0}: {1} — expected {2}, verified {3}, failed {4}, missing {5}" -f $hostName, $status, $expected, $ok, $bad.Count, $missing.Count)

if (-not $NoReport) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $repDir = Join-Path $Root '18_REPORTS'
    if (-not (Test-Path -LiteralPath $repDir)) { New-Item -ItemType Directory -Force -Path $repDir | Out-Null }
    $md = @"
# SHA-256 VERIFICATION — $hostName

| Metric | Value |
|---|---|
| Status | **$status** |
| Root | $Root |
| EXPECTED FILES | $expected |
| COPIED FILES (present) | $($expected - $missing.Count) |
| EXPECTED BYTES | $expectedBytes |
| COPIED BYTES | $copiedBytes |
| HASH VERIFIED | $ok |
| HASH FAILED | $($bad.Count) |
| MISSING | $($missing.Count) |

## Hash failures (first 200)
$(($bad | Select-Object -First 200 | ForEach-Object { "- $_" }) -join "`n")

## Missing (first 200)
$(($missing | Select-Object -First 200 | ForEach-Object { "- $_" }) -join "`n")
"@
    Set-Content -LiteralPath (Join-Path $repDir "VERIFY-$hostName-$stamp.md") -Value $md -Encoding UTF8
    $summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $repDir "VERIFY-$hostName-$stamp.json") -Encoding UTF8
}
if ($StatusFile) { $summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatusFile -Encoding UTF8 }
if ($status -eq 'PASS') { exit 0 } else { exit 1 }
