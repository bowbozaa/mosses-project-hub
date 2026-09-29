<#
.SYNOPSIS
  Phases 8,9,16,17,18,36 — create consistent local backup artifacts inside the workspace BEFORE copying:
    * git bundle --all for every repo holding data not on its remote (captures local commits + stashes)
    * working-tree patch (tracked changes) per such repo
    * sqlite3 .backup for SQLite files (consistent snapshot) when sqlite3 is available
    * portable Claude/editor config snapshot (no credentials)
    * optional: Docker volume tar (read-only mount), WSL export, Flyday Brain D1 export
  Never modifies source repos or databases.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [switch]$BundleAllRepos,
    [switch]$BackupDockerVolumes,
    [string[]]$ExportWslDistros = @(),
    [switch]$ExportBrainD1,
    [string]$BrainD1Database = 'friclawd-db',
    [string]$BrainWranglerProject = ''
)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase05-local-backups.log'
$results = New-Object System.Collections.Generic.List[object]
$csv = Join-Path $ws.Manifests 'PROJECT-INVENTORY.csv'
if (-not (Test-Path $csv)) { throw 'PROJECT-INVENTORY.csv not found — run 02-Discover-Projects.ps1 first.' }
$projects = @(Import-Csv $csv)

function Get-SafeName { param([string]$Path) return (($Path -replace '^[A-Za-z]:\\', '') -replace '[\\/:*?"<>| ]', '_') }

# --- Git bundles + patches -------------------------------------------------
$bundleDir = Join-Path $ws.Restore 'git-bundles'
foreach ($p in ($projects | Where-Object { $_.'Git?' -eq 'True' })) {
    $needs = $BundleAllRepos -or $p.Classification -ne 'REMOTE_SOURCE_OF_TRUTH'
    if (-not $needs) { continue }
    $repo = $p.'Absolute Path'
    $name = Get-SafeName $repo
    $bundle = Join-Path $bundleDir "$name.bundle"
    if (Test-Path -LiteralPath $bundle) { Write-MigLog "Bundle exists, keeping: $bundle" -Level WARN -LogFile $log; continue }
    & git -c safe.directory=* -C $repo bundle create $bundle --all 2>&1 | Out-File -Append -FilePath $log -Encoding utf8
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $bundle)
    if ($ok) {
        # Verify the bundle is readable without needing the source repo.
        $heads = @(& git bundle list-heads $bundle 2>$null)
        $ok = $heads.Count -gt 0
    }
    $patch = Join-Path $bundleDir "$name.worktree.patch"
    # --output writes bytes directly (PowerShell pipelines would re-encode binary patches).
    & git -c safe.directory=* --no-optional-locks -C $repo diff HEAD --binary "--output=$patch" 2>$null
    if ((Test-Path -LiteralPath $patch) -and (Get-Item -LiteralPath $patch -Force).Length -eq 0) { Remove-Item -LiteralPath $patch }
    $untrackedList = Join-Path $bundleDir "$name.untracked.txt"
    & git -c safe.directory=* --no-optional-locks -C $repo ls-files --others --exclude-standard 2>$null | Out-File -LiteralPath $untrackedList -Encoding utf8
    $results.Add([pscustomobject]@{ Item = $repo; Type = 'git-bundle'; Output = $bundle; Status = if ($ok) { 'PASS' } else { 'FAIL' } })
    Write-MigLog ("bundle {0}: {1}" -f $repo, $(if ($ok) { 'OK' } else { 'FAILED' })) -Level $(if ($ok) { 'OK' } else { 'ERROR' }) -LogFile $log
}

# --- SQLite consistent snapshots ------------------------------------------
$dbCsv = Join-Path $ws.Manifests 'database-files.csv'
$dbDir = Join-Path $ws.Restore 'databases'
if (Test-Path $dbCsv) {
    $sqlite = Test-CommandExists 'sqlite3'
    foreach ($d in (Import-Csv $dbCsv | Where-Object { $_.Engine -like 'SQLite*' })) {
        $out = Join-Path $dbDir ((Get-SafeName $d.Path) + '.backup.sqlite')
        if (-not $sqlite) { $results.Add([pscustomobject]@{ Item = $d.Path; Type = 'sqlite-backup'; Output = ''; Status = 'BLOCKED (sqlite3 not installed — raw copy only; stop the app before copying)' }); continue }
        if (Test-Path -LiteralPath $out) { continue }
        # sqlite3 .backup uses the online backup API: consistent even while the DB is in use. Source opened read-only.
        $uri = 'file:' + (($d.Path -replace '\\', '/') -replace '%', '%25' -replace ' ', '%20' -replace '#', '%23' -replace '\?', '%3F') + '?mode=ro'
        & sqlite3 $uri ".backup '$($out -replace '\\','/')'" 2>&1 | Out-File -Append -FilePath $log -Encoding utf8
        $check = if (Test-Path -LiteralPath $out) { (& sqlite3 $out 'PRAGMA integrity_check;' 2>&1) -join ' ' } else { 'missing' }
        $status = if ($check -eq 'ok') { 'PASS' } elseif ($check -match 'not a database|file is not') { 'NOT_APPLICABLE (not SQLite)' } else { "FAIL ($check)" }
        $results.Add([pscustomobject]@{ Item = $d.Path; Type = 'sqlite-backup'; Output = $out; Status = $status })
    }
}

# --- Portable config snapshot (no credentials) -----------------------------
$pc = Join-Path $ws.Restore 'portable-config'
$claude = Join-Path $env:USERPROFILE '.claude'
foreach ($n in 'settings.json', 'CLAUDE.md', 'keybindings.json', 'commands', 'agents', 'skills', 'hooks', 'output-styles', 'memory') {
    $src = Join-Path $claude $n
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $pc "claude\$n"
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
}
# Claude settings.json may carry env values — keep structure, mask values of secret-like env keys.
$cs = Join-Path $pc 'claude\settings.json'
if (Test-Path -LiteralPath $cs) {
    try {
        $j = Get-Content -LiteralPath $cs -Raw | ConvertFrom-Json
        if ($j.PSObject.Properties['env']) { foreach ($e in $j.env.PSObject.Properties) { if (Test-IsSecretVariableName $e.Name) { $e.Value = '<SET_ON_DESTINATION>' } } }
        $j | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cs -Encoding UTF8
    } catch { Write-MigLog "Could not sanitize $cs — removing it from snapshot to avoid leaking secrets" -Level WARN -LogFile $log; Remove-Item -LiteralPath $cs -Force }
}
foreach ($ed in @(@('vscode', (Join-Path $env:APPDATA 'Code\User')), @('cursor', (Join-Path $env:APPDATA 'Cursor\User')))) {
    foreach ($n in 'settings.json', 'keybindings.json', 'mcp.json', 'snippets') {
        $src = Join-Path $ed[1] $n
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $pc "$($ed[0])\$n"
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        }
    }
}
Copy-Item -LiteralPath (Join-Path $ws.Manifests 'vscode-extensions.txt') -Destination (Join-Path $pc 'vscode-extensions.txt') -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $ws.Manifests 'cursor-extensions.txt') -Destination (Join-Path $pc 'cursor-extensions.txt') -ErrorAction SilentlyContinue
# Guard: no secret-named files may sit in the snapshot.
foreach ($f in (Get-BackupFileList -Root $pc -IncludeSecrets)) {
    if (Test-IsSecretFileName (Split-Path $f.FullName -Leaf)) { Remove-Item -LiteralPath $f.FullName -Force; Write-MigLog "Removed secret-named file from snapshot copy: $($f.RelativePath)" -Level WARN -LogFile $log }
}
$results.Add([pscustomobject]@{ Item = 'portable config'; Type = 'config-snapshot'; Output = $pc; Status = 'DONE' })

# --- Docker volumes (optional) ---------------------------------------------
if ($BackupDockerVolumes) {
    $vd = Join-Path $ws.Restore 'docker-volumes'
    New-Item -ItemType Directory -Force -Path $vd | Out-Null
    foreach ($v in @(& docker volume ls -q 2>$null)) {
        $out = Join-Path $vd "$v.tar.gz"
        if (Test-Path -LiteralPath $out) { continue }
        # Volume mounted read-only; for databases prefer a logical dump as well (see DOCKER-MIGRATION.md).
        & docker run --rm -v "${v}:/source:ro" -v "${vd}:/backup" alpine:3 tar -czf "/backup/$v.tar.gz" -C /source . 2>&1 | Out-File -Append -FilePath $log -Encoding utf8
        $results.Add([pscustomobject]@{ Item = "docker volume $v"; Type = 'docker-volume'; Output = $out; Status = if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) { 'PASS' } else { 'FAIL' } })
    }
}

# --- WSL export (optional) -------------------------------------------------
foreach ($d in $ExportWslDistros) {
    $wd = Join-Path $ws.Restore 'wsl'
    New-Item -ItemType Directory -Force -Path $wd | Out-Null
    $out = Join-Path $wd "$d.tar"
    if (Test-Path -LiteralPath $out) { Write-MigLog "WSL export exists, keeping: $out" -Level WARN -LogFile $log; continue }
    & wsl --export $d $out 2>&1 | Out-File -Append -FilePath $log -Encoding utf8
    $results.Add([pscustomobject]@{ Item = "wsl $d"; Type = 'wsl-export'; Output = $out; Status = if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) { 'PASS' } else { 'FAIL' } })
}

# --- Flyday Brain D1 export (optional, read-only on Cloudflare) ------------
if ($ExportBrainD1) {
    $bd = Join-Path $ws.Restore 'brain'
    New-Item -ItemType Directory -Force -Path $bd | Out-Null
    $out = Join-Path $bd ("{0}-{1}.sql" -f $BrainD1Database, (Get-Date -Format 'yyyyMMdd-HHmm'))
    if (-not (Test-CommandExists 'npx')) {
        $results.Add([pscustomobject]@{ Item = "D1 $BrainD1Database"; Type = 'd1-export'; Output = ''; Status = 'BLOCKED (npx/wrangler not available)' })
    } else {
        $loc = Get-Location
        if ($BrainWranglerProject) { Set-Location $BrainWranglerProject }
        & npx --yes wrangler d1 export $BrainD1Database --remote --output $out 2>&1 | ForEach-Object { Protect-Text "$_" } | Out-File -Append -FilePath $log -Encoding utf8
        Set-Location $loc
        $ok = (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out -Force).Length -gt 0)
        $results.Add([pscustomobject]@{ Item = "D1 $BrainD1Database"; Type = 'd1-export'; Output = $out; Status = if ($ok) { 'PASS' } else { 'FAIL (wrangler login required?)' } })
    }
    $results.Add([pscustomobject]@{ Item = 'Vectorize flyday-brain-vectors'; Type = 'vector-index'; Output = ''; Status = 'NOT_APPLICABLE (no bulk export; rebuildable from D1 by the Brain API embedding job — confirm in BRAIN-RESTORE.md)' })
}

$rep = Join-Path $ws.Reports 'LOCAL-BACKUP-ARTIFACTS.md'
Set-Content -LiteralPath $rep -Encoding UTF8 -Value ("# LOCAL BACKUP ARTIFACTS`n`n" + (ConvertTo-MarkdownTable -Rows $results.ToArray() -Columns Item, Type, Status, Output))
$fails = @($results | Where-Object { $_.Status -like 'FAIL*' })
Write-PhaseStatus -Workspace $ws -Phase 'phase05-local-backups' -Status $(if ($fails.Count) { 'PARTIAL' } else { 'PASS' }) -Details @("artifacts=$($results.Count)", "failed=$($fails.Count)") -EvidencePath $rep
Write-MigLog "Phase 5 complete: $($results.Count) artifacts, $($fails.Count) failed. See $rep" -Level $(if ($fails.Count) { 'WARN' } else { 'OK' }) -LogFile $log
