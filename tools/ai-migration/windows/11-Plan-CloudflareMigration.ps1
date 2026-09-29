<#
.SYNOPSIS
  Classify every discovered project for running on Cloudflare, and compare against what is ACTUALLY deployed.
  Read-only: nothing is deployed, no secrets are read.
.DESCRIPTION
  Inputs : 01_MANIFESTS\PROJECT-INVENTORY.csv (from 02) + data\cloudflare-snapshot.json (names of deployed
           Workers / D1 / R2, taken from the Cloudflare API).
  Outputs: 00_REPORTS\CLOUDFLARE-MIGRATION-PLAN.md, 01_MANIFESTS\cloudflare-plan.csv
  Classes:
    ALREADY_ON_CLOUDFLARE  wrangler config name matches a deployed Worker (check local changes are pushed)
    READY_TO_DEPLOY        wrangler config exists but no deployed Worker has that name
    STATIC_SITE            plain HTML / static build -> Workers static assets
    FRAMEWORK_ADAPTER      Next/Nuxt/Remix/Astro/SvelteKit/Hono... -> Cloudflare adapter
    NODE_SERVER_PORT       Express/Fastify/Koa server -> port routes to Hono on Workers
    PYTHON_REVIEW          Python app -> Python Workers (limited libs) or Cloudflare Containers
    CONTAINER_REVIEW       Dockerfile/compose -> Cloudflare Containers, or keep on a VPS
    KEEP_OFF_CLOUDFLARE    n8n, desktop tools, local AI (Ollama) — not a fit for Workers
    NOT_A_WEB_APP          no web/server indicators (library, scripts, docs)
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [string]$SnapshotFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/cloudflare-snapshot.json')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$inv = Join-Path $ws.Manifests 'PROJECT-INVENTORY.csv'
if (-not (Test-Path -LiteralPath $inv)) { throw 'PROJECT-INVENTORY.csv not found — run 02-Discover-Projects.ps1 first.' }
if (-not (Test-Path -LiteralPath $SnapshotFile)) { throw "Cloudflare snapshot not found: $SnapshotFile" }
$snap = Get-Content -LiteralPath $SnapshotFile -Raw | ConvertFrom-Json
$deployed = @($snap.workers)

function Get-WranglerName {
    param([string]$Dir)
    foreach ($f in 'wrangler.toml', 'wrangler.jsonc', 'wrangler.json') {
        $p = Join-Path $Dir $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $txt = Get-Content -LiteralPath $p -Raw
        $m = if ($f -like '*.toml') { [regex]::Match($txt, '(?m)^\s*name\s*=\s*["'']([^"'']+)["'']') } else { [regex]::Match($txt, '"name"\s*:\s*"([^"]+)"') }
        return [pscustomobject]@{ File = $f; Name = if ($m.Success) { $m.Groups[1].Value } else { '' } }
    }
    return $null
}
function Get-PackageDeps {
    param([string]$Dir)
    $p = Join-Path $Dir 'package.json'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try {
        $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $names = @()
        foreach ($k in 'dependencies', 'devDependencies') { if ($j.PSObject.Properties[$k]) { $names += @($j.$k.PSObject.Properties | ForEach-Object { $_.Name }) } }
        return $names
    } catch { return @() }
}

$rows = foreach ($p in (Import-Csv -LiteralPath $inv)) {
    $dir = $p.'Absolute Path'
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $w = Get-WranglerName $dir
    $deps = @(Get-PackageDeps $dir)
    $has = { param($n) Test-Path -LiteralPath (Join-Path $dir $n) }
    $cls = ''; $target = ''; $effort = ''; $next = ''
    $localWork = ([int]("0" + $p.'Dirty?') -gt 0) -or ([int]("0" + $p.'Unpushed Commits?') -gt 0) -or ($p.'Git?' -ne 'True')

    if ($w -and $w.Name -and ($deployed -contains $w.Name)) {
        $cls = 'ALREADY_ON_CLOUDFLARE'; $target = "Worker '$($w.Name)'"; $effort = 'none'
        $next = if ($localWork) { 'Local code differs from git remote — commit/push so the deployed Worker is reproducible' } else { 'Nothing to move' }
    } elseif ($w) {
        $cls = 'READY_TO_DEPLOY'; $target = "Worker '$($w.Name)' ($($w.File))"; $effort = 'low'
        $next = 'Set secrets (wrangler secret put), then wrangler deploy — needs your approval (production)'
    } elseif ($dir -match '(?i)n8n' -or $deps -contains 'n8n' -or $dir -match '(?i)ollama') {
        $cls = 'KEEP_OFF_CLOUDFLARE'; $target = 'n8n Cloud / VPS / local'; $effort = 'n/a'; $next = 'Not a Workers workload'
    } elseif (@($deps | Where-Object { $_ -in 'next', 'nuxt', '@remix-run/node', '@remix-run/react', 'astro', '@sveltejs/kit', 'hono', '@react-router/dev', 'vite' }).Count) {
        $fw = (@($deps | Where-Object { $_ -in 'next', 'nuxt', '@remix-run/react', 'astro', '@sveltejs/kit', 'hono', '@react-router/dev', 'vite' }) -join ',')
        $cls = 'FRAMEWORK_ADAPTER'; $target = "Workers ($fw)"; $effort = if ($deps -contains 'next') { 'medium' } else { 'low' }
        $next = 'Add the framework''s Cloudflare adapter (Next -> OpenNext; Vite SPA -> static assets), create wrangler config, deploy preview first'
    } elseif (@($deps | Where-Object { $_ -in 'express', 'fastify', 'koa', '@nestjs/core' }).Count) {
        $cls = 'NODE_SERVER_PORT'; $target = 'Worker (Hono)'; $effort = 'medium-high'
        $next = 'Port routes to Hono; replace fs/sockets/long-running jobs with R2/D1/Queues/Cron Triggers'
    } elseif ((& $has 'requirements.txt') -or (& $has 'pyproject.toml') -or (& $has 'Pipfile')) {
        $cls = 'PYTHON_REVIEW'; $target = 'Python Workers or Cloudflare Containers'; $effort = 'high'
        $next = 'Check dependencies against Python Workers support; otherwise containerize'
    } elseif ((& $has 'Dockerfile') -or (& $has 'docker-compose.yml') -or (& $has 'compose.yml')) {
        $cls = 'CONTAINER_REVIEW'; $target = 'Cloudflare Containers or VPS'; $effort = 'high'
        $next = 'Stateful services (DBs) stay on managed DB/VPS; stateless images may fit Containers'
    } elseif ((& $has 'index.html') -or (& $has 'public/index.html') -or (& $has 'dist/index.html')) {
        $cls = 'STATIC_SITE'; $target = 'Workers static assets'; $effort = 'low'
        $next = 'wrangler.jsonc with assets.directory, then deploy preview'
    } else {
        $cls = 'NOT_A_WEB_APP'; $target = '—'; $effort = 'n/a'; $next = 'Keep in git; nothing to host'
    }
    [pscustomobject]@{
        Project = $p.'Project Name'; Path = $dir; Class = $cls; Target = $target; Effort = $effort
        LocalUnpushedWork = $localWork; Remote = $p.'Remote URL'; NextStep = $next
    }
}
$rows = @($rows)
$matchedNames = @($rows | Where-Object { $_.Class -eq 'ALREADY_ON_CLOUDFLARE' } | ForEach-Object { ($_.Target -replace "^Worker '|'$", '') })
$noLocal = @($deployed | Where-Object { $matchedNames -notcontains $_ })

$rows | Export-Csv -LiteralPath (Join-Path $ws.Manifests 'cloudflare-plan.csv') -NoTypeInformation -Encoding UTF8
$counts = $rows | Group-Object Class | Sort-Object Count -Descending | ForEach-Object { "| $($_.Name) | $($_.Count) |" }
$toMove = @($rows | Where-Object { $_.Class -in 'READY_TO_DEPLOY', 'STATIC_SITE', 'FRAMEWORK_ADAPTER', 'NODE_SERVER_PORT', 'PYTHON_REVIEW', 'CONTAINER_REVIEW' } | Sort-Object Effort)
$md = @"
# CLOUDFLARE MIGRATION PLAN

Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm')) · Cloudflare snapshot: $($snap.snapshotDate) ($($deployed.Count) Workers, $(@($snap.d1).Count) D1, $(@($snap.r2).Count) R2)

Nothing was deployed. Every deploy is a production change and needs explicit approval per project.

## Summary

| Class | Projects |
|---|---|
$($counts -join "`n")

## Candidates to move (lowest effort first)

$(ConvertTo-MarkdownTable -Rows $toMove -Columns Project, Class, Target, Effort, LocalUnpushedWork, NextStep, Path)

## Already on Cloudflare

$(ConvertTo-MarkdownTable -Rows @($rows | Where-Object Class -eq 'ALREADY_ON_CLOUDFLARE') -Columns Project, Target, LocalUnpushedWork, NextStep)

## Keep off Cloudflare / nothing to host

$(ConvertTo-MarkdownTable -Rows @($rows | Where-Object { $_.Class -in 'KEEP_OFF_CLOUDFLARE', 'NOT_A_WEB_APP' }) -Columns Project, Class, Target, Path)

## Deployed Workers with no matching project on this notebook ($($noLocal.Count))

Their code lives elsewhere (GitHub / another machine) or the wrangler ``name`` differs from the folder. Confirm each has a git
source of truth before the notebook is wiped:

$(($noLocal | Sort-Object | ForEach-Object { "- $_" }) -join "`n")

## Never runs on Cloudflare
Claude Code, Claude Desktop, VS Code, Cursor, Docker Desktop, WSL, Ollama models — these are workstation tools and are
rebuilt on friclawd / Mac with the bootstrap scripts.
"@
$out = Join-Path $ws.Reports 'CLOUDFLARE-MIGRATION-PLAN.md'
Set-Content -LiteralPath $out -Value $md -Encoding UTF8
Write-PhaseStatus -Workspace $ws -Phase 'phase11-cloudflare-plan' -Status 'DONE' -Details @("projects=$($rows.Count)", "to_move=$($toMove.Count)", "deployed_without_local=$($noLocal.Count)") -EvidencePath $out
Write-MigLog "Cloudflare plan: $($toMove.Count) candidates to move, $(@($rows | Where-Object Class -eq 'ALREADY_ON_CLOUDFLARE').Count) already deployed. $out" -Level OK
