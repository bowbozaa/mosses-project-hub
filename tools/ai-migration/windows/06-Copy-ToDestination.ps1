<#
.SYNOPSIS
  Phases 22-25 — capacity check + COPY-ONLY robocopy of reviewed sources to a destination (friclawd SMB share).
.DESCRIPTION
  * Reads 01_MANIFESTS\migration-sources.json (review include flags first).
  * Refuses destructive robocopy flags (/MIR /PURGE /MOV /MOVE) — enforced in code.
  * Secret files (.env, keys, credentials) are excluded here; they go to the encrypted archive (08).
  * Refuses to write into a non-empty destination folder unless -Resume is given (resume of our own copy).
  * One log per source in 02_LOGS\copy-*.log.
.EXAMPLE
  pwsh -File .\06-Copy-ToDestination.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration' -DryRun
  pwsh -File .\06-Copy-ToDestination.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestinationRoot,
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [string]$SourcesFile,
    [int]$SafetyMarginPercent = 15,
    [int]$Threads = 8,
    [switch]$Resume,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase06-copy.log'
if (-not $SourcesFile) { $SourcesFile = Join-Path $ws.Manifests 'migration-sources.json' }
if (-not (Test-Path -LiteralPath $SourcesFile)) { throw "Sources file not found: $SourcesFile (run 02-Discover-Projects.ps1)" }
$cfg = Get-Content -LiteralPath $SourcesFile -Raw | ConvertFrom-Json
$excludeDirs = @($cfg.excludeDirs)
$excludeFiles = @(Get-SecretFilePatterns)

# --- 1. Connectivity -------------------------------------------------------
if ($DestinationRoot -match '^\\\\([^\\]+)\\') {
    $destHost = $Matches[1]
    $smb = Test-NetConnection -ComputerName $destHost -Port 445 -WarningAction SilentlyContinue
    if (-not $smb.TcpTestSucceeded) {
        Write-PhaseStatus -Workspace $ws -Phase 'phase06-copy' -Status 'BLOCKED' -Details @("SMB 445 unreachable on $destHost")
        throw "SMB (445) not reachable on $destHost. Check Tailscale (tailscale status) and the share on the destination."
    }
    Write-MigLog "SMB reachable on $destHost" -Level OK -LogFile $log
}
if (-not (Test-Path -LiteralPath $DestinationRoot)) {
    if ($DryRun) { Write-MigLog "DryRun: would create $DestinationRoot" -LogFile $log }
    else { New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null }
}

# --- 2. Build copy plan ----------------------------------------------------
$plan = New-Object System.Collections.Generic.List[object]
foreach ($s in $cfg.sources) {
    if (-not $s.include) { continue }
    if (-not (Test-Path -LiteralPath $s.path)) { Write-MigLog "Source missing, skipped: $($s.path)" -Level WARN -LogFile $log; continue }
    $extraX = @()
    if ($s.PSObject.Properties['excludeDirs']) { $extraX = @($s.excludeDirs) }
    if ($s.path -match '\\\.cursor$') { $extraX += 'extensions' }
    if ($s.path -match '\\\.claude$') { $extraX += @('shell-snapshots', 'statsig', 'cache', 'debug', 'telemetry') }
    $plan.Add([pscustomobject]@{ Name = $s.name; Source = $s.path; RelDest = $s.destination; Destination = Join-Path $DestinationRoot $s.destination; ExtraExcludeDirs = $extraX; SizeBytes = [long]("0" + $s.sizeBytes) })
}
# Workspace artifacts (reports, bundles, DB snapshots, portable config) go to their structured folders.
$wsMap = @(
    @($ws.Root, '00_MANIFEST\AI-MIGRATION-WORK'),
    @($ws.Reports, '18_REPORTS'),
    @((Join-Path $ws.Restore 'git-bundles'), '13_GIT\bundles'),
    @((Join-Path $ws.Restore 'databases'), '11_DATABASES\sqlite-snapshots'),
    @((Join-Path $ws.Restore 'portable-config'), '14_CONFIG\portable-config'),
    @((Join-Path $ws.Restore 'docker-volumes'), '09_DOCKER\volumes'),
    @((Join-Path $ws.Restore 'wsl'), '10_WSL'),
    @((Join-Path $ws.Restore 'brain'), '02_AI_BRAIN\d1-export')
)
foreach ($m in $wsMap) {
    if (Test-Path -LiteralPath $m[0]) {
        # The workspace root copy skips 04_RESTORE: those artifacts are copied to their own folders below.
        $wx = if ($m[0] -eq $ws.Root) { @('04_RESTORE') } else { @() }
        $plan.Add([pscustomobject]@{ Name = "workspace:$($m[1])"; Source = $m[0]; RelDest = $m[1]; Destination = Join-Path $DestinationRoot $m[1]; ExtraExcludeDirs = $wx; SizeBytes = (Get-DirectorySizeBytes -Path $m[0] -ExcludeDirs $wx) })
    }
}

# The plan is the contract for hashing (07) — same sources, same exclusions.
[ordered]@{ destinationRoot = $DestinationRoot; excludeDirs = $excludeDirs; created = (Get-Date).ToString('o'); items = $plan } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ws.Manifests 'copy-plan.json') -Encoding UTF8

# --- 3. Capacity check -----------------------------------------------------
$needed = ($plan | Measure-Object -Property SizeBytes -Sum).Sum
$space = Get-FreeSpaceBytes -Path $DestinationRoot
if ($null -eq $space) {
    Write-MigLog 'Could not read destination free space — continuing only in DryRun; check manually.' -Level WARN -LogFile $log
    if (-not $DryRun) { throw 'Destination free space unknown. Verify capacity manually, then re-run.' }
} else {
    $usable = [long]($space.FreeBytes * (100 - $SafetyMarginPercent) / 100)
    Write-MigLog ("Need {0}; destination free {1} (usable after {2}% margin: {3})" -f (Format-Bytes $needed), (Format-Bytes $space.FreeBytes), $SafetyMarginPercent, (Format-Bytes $usable)) -LogFile $log
    if ($needed -gt $usable -and -not $Resume) {
        Write-PhaseStatus -Workspace $ws -Phase 'phase06-copy' -Status 'BLOCKED' -Details @('INSUFFICIENT_DESTINATION_SPACE', "need=$needed", "usable=$usable")
        Write-MigLog 'INSUFFICIENT_DESTINATION_SPACE — nothing copied.' -Level ERROR -LogFile $log
        exit 2
    }
}

# --- 4. Create structure ---------------------------------------------------
$structure = '00_MANIFEST', '01_PROJECTS', '02_AI_BRAIN', '03_MCP', '04_SKILLS', '05_AGENTS', '06_PROMPTS', '07_CLAUDE', '08_N8N', '09_DOCKER', '10_WSL', '11_DATABASES', '12_AUTOMATION', '13_GIT', '14_CONFIG', '15_VSCODE_CURSOR', '16_ARCHIVE', '17_RESTORE_TOOLS', '18_REPORTS', '99_ENCRYPTED_SECRETS'
if (-not $DryRun) { foreach ($d in $structure) { New-Item -ItemType Directory -Force -Path (Join-Path $DestinationRoot $d) | Out-Null } }

# --- 5. Copy -----------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
foreach ($item in $plan) {
    $isWorkspace = $item.Name -like 'workspace:*'
    if (-not $isWorkspace -and -not $Resume -and (Test-Path -LiteralPath $item.Destination) -and @(Get-ChildItem -LiteralPath $item.Destination -Force | Select-Object -First 1).Count) {
        Write-MigLog "Destination not empty, skipped (use -Resume to continue our own earlier copy): $($item.Destination)" -Level WARN -LogFile $log
        $results.Add([pscustomobject]@{ Name = $item.Name; Source = $item.Source; Destination = $item.Destination; ExitCode = ''; Status = 'SKIPPED_DEST_NOT_EMPTY'; Files = ''; Bytes = ''; Failed = ''; Start = ''; End = ''; Log = '' })
        continue
    }
    $safe = ($item.Name -replace '[\\/:*?"<>| ]', '_')
    $itemLog = Join-Path $ws.Logs "copy-$safe.log"
    $xd = @($excludeDirs + $item.ExtraExcludeDirs)
    $rcArgs = @($item.Source, $item.Destination, '/E', '/Z', '/R:2', '/W:5', '/COPY:DAT', '/DCOPY:T', '/XJ', '/FFT', "/MT:$Threads", '/NP', '/NDL', '/NFL', "/UNILOG:$itemLog")
    if ($xd.Count) { $rcArgs += '/XD'; $rcArgs += $xd }
    if ($excludeFiles.Count) { $rcArgs += '/XF'; $rcArgs += $excludeFiles }
    if ($DryRun) { $rcArgs += '/L' }
    Assert-SafeRobocopyArgs -Arguments $rcArgs
    $start = Get-Date
    Write-MigLog ("{0}robocopy {1} -> {2}" -f $(if ($DryRun) { '[DRYRUN] ' } else { '' }), $item.Source, $item.Destination) -LogFile $log
    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    $end = Get-Date
    # Parse robocopy summary (last "Files :" / "Bytes :" lines; columns Total Copied Skipped Mismatch FAILED Extras).
    $files = ''; $bytes = ''; $failed = ''
    if (Test-Path -LiteralPath $itemLog) {
        $txt = Get-Content -LiteralPath $itemLog -Encoding Unicode -ErrorAction SilentlyContinue
        $fl = $txt | Where-Object { $_ -match '^\s*Files\s*:\s*\d' } | Select-Object -Last 1
        $bl = $txt | Where-Object { $_ -match '^\s*Bytes\s*:\s*[\d\.]' } | Select-Object -Last 1
        if ($fl) { $c = ($fl -split ':', 2)[1].Trim() -split '\s+'; $files = "total=$($c[0]) copied=$($c[1]) skipped=$($c[2]) failed=$($c[4])"; $failed = $c[4] }
        if ($bl) { $bytes = ($bl -split ':', 2)[1].Trim() -replace '\s+', ' ' }
    }
    $status = if ($code -ge 8) { 'FAIL' } elseif ($failed -and $failed -ne '0') { 'PARTIAL' } else { 'PASS' }
    $results.Add([pscustomobject]@{ Name = $item.Name; Source = $item.Source; Destination = $item.Destination; ExitCode = $code; Status = $status; Files = $files; Bytes = $bytes; Failed = $failed; Start = $start.ToString('s'); End = $end.ToString('s'); Log = $itemLog })
    Write-MigLog ("  exit={0} status={1} {2}" -f $code, $status, $files) -Level $(if ($status -eq 'PASS') { 'OK' } else { 'ERROR' }) -LogFile $log
}

$rep = Join-Path $ws.Reports 'COPY-REPORT.md'
$md = "# COPY REPORT`n`nDestination: ``$DestinationRoot``  DryRun: $DryRun  Resume: $Resume`n`nExcluded dirs: $($excludeDirs -join ', ')`n`nExcluded secret files (→ 08 encrypted archive): $($excludeFiles -join ', ')`n`n" +
    (ConvertTo-MarkdownTable -Rows $results.ToArray() -Columns Name, Status, ExitCode, Files, Bytes, Start, End, Source, Destination)
Set-Content -LiteralPath $rep -Value $md -Encoding UTF8
$results | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $ws.Manifests 'copy-results.json') -Encoding UTF8
if (-not $DryRun) { Copy-Item -LiteralPath $rep -Destination (Join-Path $DestinationRoot '18_REPORTS\COPY-REPORT.md') -Force }

$bad = @($results | Where-Object { $_.Status -ne 'PASS' })
$final = if ($DryRun) { 'DONE' } elseif ($bad.Count) { 'PARTIAL' } else { 'PASS' }
Write-PhaseStatus -Workspace $ws -Phase $(if ($DryRun) { 'phase06-copy-dryrun' } else { 'phase06-copy' }) -Status $final -Details @("destination=$DestinationRoot", "items=$($results.Count)", "not_pass=$($bad.Count)") -EvidencePath $rep
Write-MigLog "Copy phase finished: $final. Next: 07-New-HashManifest.ps1 then Test-Sha256Sums.ps1 against the destination." -Level $(if ($final -in 'PASS', 'DONE') { 'OK' } else { 'WARN' }) -LogFile $log
