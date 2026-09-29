<#
.SYNOPSIS
  Phases 16,17,19 — Docker, WSL, Ollama inventory. Read-only: no prune, no stop, no unregister.
.OUTPUTS
  00_REPORTS\DOCKER-MIGRATION.md, WSL-MIGRATION.md, OLLAMA-MODEL-MANIFEST.md
#>
[CmdletBinding()]
param([string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'))
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase04-services.log'

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
$dockerMd = "# DOCKER MIGRATION`n`n"
$dockerDetail = 'not installed'
if (Test-CommandExists 'docker') {
    & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $dockerDetail = 'CLI present, engine not running'
        $dockerMd += "Docker CLI found but the engine is not running. Start Docker Desktop and re-run this script, otherwise volume data cannot be inventoried.`n`nSTATUS: BLOCKED`n"
    } else {
        $fmt = '{{json .}}'
        $containers = @(& docker ps -a --format $fmt 2>$null | ForEach-Object { $_ | ConvertFrom-Json })
        $volumes = @(& docker volume ls --format $fmt 2>$null | ForEach-Object { $_ | ConvertFrom-Json })
        $images = @(& docker images --format $fmt 2>$null | ForEach-Object { $_ | ConvertFrom-Json })
        $compose = @(& docker compose ls -a --format json 2>$null | ConvertFrom-Json)
        $mounts = foreach ($c in $containers) {
            $insp = & docker inspect $c.ID 2>$null | ConvertFrom-Json
            foreach ($m in $insp.Mounts) {
                [pscustomobject]@{ Container = $c.Names; Image = $c.Image; Type = $m.Type; Source = if ($m.Type -eq 'volume') { $m.Name } else { $m.Source }; Target = $m.Destination; RW = $m.RW }
            }
        }
        $mounts = @($mounts)
        $dbLike = '(?i)postgres|mysql|mariadb|mongo|redis|n8n|qdrant|chroma|weaviate|milvus|supabase|pgvector'
        $volRows = foreach ($v in $volumes) {
            $users = @($mounts | Where-Object { $_.Type -eq 'volume' -and $_.Source -eq $v.Name })
            $imgs = ($users | ForEach-Object { $_.Image } | Select-Object -Unique) -join ', '
            [pscustomobject]@{
                Volume = $v.Name; UsedBy = (($users | ForEach-Object { $_.Container }) -join ', '); Images = $imgs
                Classification = if ($imgs -match $dbLike -or $v.Name -match $dbLike) { 'CUSTOM_DATA (likely database — logical dump + volume tar)' } elseif (-not $users) { 'UNKNOWN (orphan — do not assume disposable)' } else { 'REVIEW' }
            }
        }
        $dockerDetail = "containers=$($containers.Count) volumes=$($volumes.Count)"
        $dockerMd += @"
Engine running. Nothing was stopped, removed or pruned.

## Containers ($($containers.Count))

$(ConvertTo-MarkdownTable -Rows @($containers | ForEach-Object { [pscustomobject]@{ Name = $_.Names; Image = $_.Image; State = $_.State; Status = $_.Status; Ports = $_.Ports } }) -Columns Name, Image, State, Status, Ports)

## Volumes ($($volumes.Count)) — data that exists ONLY inside Docker

$(ConvertTo-MarkdownTable -Rows @($volRows) -Columns Volume, UsedBy, Images, Classification)

## Mounts

$(ConvertTo-MarkdownTable -Rows $mounts -Columns Container, Image, Type, Source, Target, RW)

## Compose projects

$(ConvertTo-MarkdownTable -Rows @($compose | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = $_.Status; ConfigFiles = $_.ConfigFiles } }) -Columns Name, Status, ConfigFiles)

## Images ($($images.Count)) — re-pullable unless built locally

$(ConvertTo-MarkdownTable -Rows @($images | ForEach-Object { [pscustomobject]@{ Repository = $_.Repository; Tag = $_.Tag; Size = $_.Size; Created = $_.CreatedSince } }) -Columns Repository, Tag, Size, Created)

## Backup plan
1. Database containers: logical dump first (``pg_dump`` / ``mysqldump`` / ``mongodump``) — run manually per container.
2. Volumes: ``05-Prepare-LocalBackups.ps1 -BackupDockerVolumes`` (read-only mount, tar.gz per volume).
3. Bind-mount sources are ordinary folders — confirm they are listed in migration-sources.json.
4. Compose files travel with their projects.
"@
        $volRows | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $ws.Manifests 'docker-volumes.json') -Encoding UTF8
    }
} else { $dockerMd += "Docker not installed.`n`nSTATUS: NOT_APPLICABLE`n" }
Set-Content -LiteralPath (Join-Path $ws.Reports 'DOCKER-MIGRATION.md') -Value $dockerMd -Encoding UTF8

# ---------------------------------------------------------------------------
# WSL
# ---------------------------------------------------------------------------
$wslMd = "# WSL MIGRATION`n`n"
$distros = @()
if (Test-CommandExists 'wsl') {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode   # wsl.exe writes UTF-16
        $raw = @(& wsl --list --verbose 2>$null)
    } finally { [Console]::OutputEncoding = $prev }
    foreach ($line in ($raw | Select-Object -Skip 1)) {
        $l = ($line -replace "`0", '').Trim()
        if (-not $l) { continue }
        $default = $l.StartsWith('*')
        $parts = ($l.TrimStart('*').Trim() -split '\s+')
        if ($parts.Count -ge 3) { $distros += [pscustomobject]@{ Name = $parts[0]; State = $parts[1]; Version = $parts[2]; Default = $default } }
    }
    $rows = foreach ($d in $distros) {
        $homeInfo = ''
        if ($d.State -eq 'Running') {
            # Only inspects when already running — never starts a stopped distro implicitly.
            $homeInfo = (& wsl -d $d.Name -- sh -c 'du -sh ~ 2>/dev/null; ls ~ 2>/dev/null | head -40 | tr "\n" " "' 2>$null) -join ' '
        } else { $homeInfo = '(stopped — start it and re-run, or inspect \\wsl$\' + $d.Name + '\home)' }
        [pscustomobject]@{ Name = $d.Name; State = $d.State; Version = $d.Version; Default = $d.Default; HomeSummary = $homeInfo }
    }
    $wslMd += @"
Distributions: $(@($distros).Count). Nothing was unregistered or terminated.

$(ConvertTo-MarkdownTable -Rows @($rows) -Columns Name, State, Version, Default, HomeSummary)

## Backup
- Unique data inside a distro → ``05-Prepare-LocalBackups.ps1 -ExportWslDistros <name>`` (``wsl --export`` to a .tar; non-destructive).
- ``docker-desktop`` / ``docker-desktop-data`` distros are managed by Docker Desktop — back up Docker volumes instead.
"@
} else { $wslMd += "WSL not installed.`n`nSTATUS: NOT_APPLICABLE`n" }
Set-Content -LiteralPath (Join-Path $ws.Reports 'WSL-MIGRATION.md') -Value $wslMd -Encoding UTF8

# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------
$ollamaDir = Join-Path $env:USERPROFILE '.ollama'
$manifestRoot = Join-Path $ollamaDir 'models\manifests'
$models = @()
if (Test-Path -LiteralPath $manifestRoot) {
    foreach ($f in Get-ChildItem -LiteralPath $manifestRoot -Recurse -File -ErrorAction SilentlyContinue) {
        $rel = $f.FullName.Substring($manifestRoot.Length + 1).Split('\')   # host\namespace\model\tag
        if ($rel.Count -lt 4) { continue }
        $hostName = $rel[0]; $ns = $rel[1]; $model = $rel[2]; $tag = $rel[3]
        $size = 0
        try { $m = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; $size = ($m.layers | Measure-Object -Property size -Sum).Sum } catch { }
        $cls = if ($hostName -eq 'registry.ollama.ai' -and $ns -eq 'library') { 'DOWNLOADABLE_STANDARD_MODEL' }
        elseif ($hostName -eq 'registry.ollama.ai') { 'DOWNLOADABLE (user namespace — verify it is published)' }
        else { 'CUSTOM_MODEL (back up)' }
        $name = if ($ns -eq 'library') { "${model}:$tag" } else { "$ns/${model}:$tag" }
        $models += [pscustomobject]@{ Model = $name; Registry = $hostName; Size = Format-Bytes $size; Classification = $cls; Restore = if ($cls -like 'DOWNLOADABLE_STANDARD*') { "ollama pull $name" } else { 'restore from backup / ollama create from Modelfile' } }
    }
}
$custom = @($models | Where-Object { $_.Classification -notlike 'DOWNLOADABLE_STANDARD*' })
$ollamaMd = @"
# OLLAMA MODEL MANIFEST

Ollama dir: ``$ollamaDir`` ($(if (Test-Path -LiteralPath $ollamaDir) { Format-Bytes (Get-DirectorySizeBytes -Path $ollamaDir) } else { 'not present' }))

$(ConvertTo-MarkdownTable -Rows @($models) -Columns Model, Registry, Size, Classification, Restore)

Custom / non-standard models: **$($custom.Count)**. $(if ($custom.Count) { 'Set include=true for .ollama in migration-sources.json.' } else { 'All models are re-downloadable; .ollama can stay excluded from the backup.' })

Restore script (standard models):

``````
$(($models | Where-Object { $_.Classification -like 'DOWNLOADABLE_STANDARD*' } | ForEach-Object { "ollama pull $($_.Model)" }) -join "`n")
``````
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'OLLAMA-MODEL-MANIFEST.md') -Value $ollamaMd -Encoding UTF8
$models | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $ws.Manifests 'ollama-models.json') -Encoding UTF8

Write-PhaseStatus -Workspace $ws -Phase 'phase04-services' -Status 'DONE' -Details @("docker: $dockerDetail", "wsl_distros=$(@($distros).Count)", "ollama_models=$($models.Count) custom=$($custom.Count)")
Write-MigLog 'Phase 4 complete (Docker, WSL, Ollama).' -Level OK -LogFile $log
