<#
.SYNOPSIS
  Phases 35/38 (Windows side) — verify a rebuilt Windows workstation with evidence. Read-only.
.OUTPUTS
  ~\AI-RESTORE-LOGS\VERIFY-ENVIRONMENT-<host>-<ts>.md (+ .json)
#>
[CmdletBinding()]
param(
    [string]$ProjectsRoot = (Join-Path $env:USERPROFILE 'Projects'),
    [string[]]$RequiredTools = @('git', 'gh', 'node', 'npm', 'python', 'uv', 'code', 'claude', 'tailscale', '7z')
)
$ErrorActionPreference = 'Continue'
$rows = New-Object System.Collections.Generic.List[object]
function Add-Row { param($Check, $Status, $Evidence) $rows.Add([pscustomobject]@{ Check = $Check; Status = $Status; Evidence = $Evidence }) }

foreach ($t in $RequiredTools) {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if (-not $c) { Add-Row "tool: $t" 'FAIL' 'not on PATH'; continue }
    $v = try { (& $t --version 2>&1 | Select-Object -First 1) -join '' } catch { '' }
    if ($t -eq '7z') { $v = 'present' }
    Add-Row "tool: $t" 'PASS' $v
}
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    & tailscale status 2>&1 | Out-Null
    Add-Row 'tailscale connected' $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) "exit $LASTEXITCODE"
}
if (Get-Command gh -ErrorAction SilentlyContinue) {
    & gh auth status 2>&1 | Out-Null
    Add-Row 'gh authenticated' $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'gh auth status (output not logged)'
}
$claudeHome = Join-Path $env:USERPROFILE '.claude'
$skills = @(Get-ChildItem -LiteralPath (Join-Path $claudeHome 'skills') -Recurse -Filter 'SKILL.md' -ErrorAction SilentlyContinue).Count
Add-Row 'Claude skills restored' $(if ($skills -gt 0) { 'PASS' } else { 'PARTIAL' }) "SKILL.md count=$skills"
$agents = @(Get-ChildItem -LiteralPath (Join-Path $claudeHome 'agents') -Filter '*.md' -ErrorAction SilentlyContinue).Count
Add-Row 'Claude agents restored' $(if ($agents -gt 0) { 'PASS' } else { 'PARTIAL' }) "agents=$agents"
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $mcp = (& claude mcp list 2>&1) -join ' '
    Add-Row 'Claude MCP servers' $(if ($mcp -match '(?i)connected') { 'PASS' } else { 'PARTIAL' }) ('claude mcp list: ' + ($mcp.Length) + ' chars (not logged)')
}
$repos = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') })
Add-Row 'repos in ProjectsRoot' $(if ($repos.Count) { 'PASS' } else { 'FAIL' }) "$($repos.Count) under $ProjectsRoot"
foreach ($r in $repos) {
    & git -c safe.directory=* --no-optional-locks -C $r.FullName fsck --connectivity-only --no-dangling 2>$null | Out-Null
    Add-Row "git fsck: $($r.Name)" $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) "exit $LASTEXITCODE"
}
if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker info 2>&1 | Out-Null
    Add-Row 'docker engine' $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'PARTIAL' }) "exit $LASTEXITCODE (start Docker Desktop if PARTIAL)"
}

$fail = @($rows | Where-Object Status -eq 'FAIL').Count
$overall = if ($fail) { 'FAIL' } elseif (@($rows | Where-Object Status -eq 'PARTIAL').Count) { 'PARTIAL' } else { 'PASS' }
$dir = Join-Path $env:USERPROFILE 'AI-RESTORE-LOGS'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$md = "# VERIFY ENVIRONMENT — $env:COMPUTERNAME ($stamp)`n`n**Overall: $overall**`n`n| Check | Status | Evidence |`n|---|---|---|`n" + (($rows | ForEach-Object { "| $($_.Check) | $($_.Status) | $($_.Evidence -replace '\|','/') |" }) -join "`n")
Set-Content -LiteralPath (Join-Path $dir "VERIFY-ENVIRONMENT-$env:COMPUTERNAME-$stamp.md") -Value $md -Encoding UTF8
[ordered]@{ status = $overall; host = $env:COMPUTERNAME; timestamp = (Get-Date).ToString('o'); checks = $rows } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir "VERIFY-ENVIRONMENT-$env:COMPUTERNAME-$stamp.json") -Encoding UTF8
Write-Host "Environment verification: $overall — $dir"
