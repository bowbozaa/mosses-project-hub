<#
.SYNOPSIS
  Phase 29 — restore PORTABLE config (Claude commands/agents/skills/hooks, editor settings, extensions,
  Ollama standard models). Never overwrites an existing file. Authentication is NOT restored — sign in again.
.EXAMPLE
  pwsh -File .\restore-config-windows.ps1 -BackupRoot 'D:\Backup\Mosses-AI-Migration' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$BackupRoot,
    [switch]$InstallExtensions,
    [switch]$PullOllamaModels
)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$pc = Join-Path $BackupRoot '14_CONFIG\portable-config'
if (-not (Test-Path -LiteralPath $pc)) { throw "portable-config not found under $BackupRoot" }

function Copy-NoOverwrite {
    [CmdletBinding(SupportsShouldProcess)]
    param($From, $To)
    if (-not (Test-Path -LiteralPath $From)) { return }
    if ((Get-Item -LiteralPath $From -Force).PSIsContainer) {
        $a = @($From, $To, '/E', '/XC', '/XN', '/XO', '/XJ', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH')
        Assert-SafeRobocopyArgs -Arguments $a
        if ($PSCmdlet.ShouldProcess($To, "copy missing files from $From")) { & robocopy @a | Out-Null; Write-Host "  $From -> $To (exit $LASTEXITCODE)" }
    } elseif (Test-Path -LiteralPath $To) {
        Write-Host "  [keep] $To exists — compare manually with $From" -ForegroundColor Yellow
    } elseif ($PSCmdlet.ShouldProcess($To, "copy $From")) {
        New-Item -ItemType Directory -Force -Path (Split-Path $To -Parent) | Out-Null
        Copy-Item -LiteralPath $From -Destination $To
        Write-Host "  [new] $To" -ForegroundColor Green
    }
}

Write-Host 'Claude Code portable config'
$claudeHome = Join-Path $env:USERPROFILE '.claude'
foreach ($n in 'commands', 'agents', 'skills', 'hooks', 'output-styles', 'memory') { Copy-NoOverwrite (Join-Path $pc "claude\$n") (Join-Path $claudeHome $n) }
foreach ($n in 'CLAUDE.md', 'settings.json', 'keybindings.json') { Copy-NoOverwrite (Join-Path $pc "claude\$n") (Join-Path $claudeHome $n) }
Write-Host '  settings.json env values marked <SET_ON_DESTINATION> must be filled in by you. Hooks referencing Windows paths: check CLAUDE-INVENTORY.md.'

foreach ($ed in @(@('vscode', (Join-Path $env:APPDATA 'Code\User'), 'code'), @('cursor', (Join-Path $env:APPDATA 'Cursor\User'), 'cursor'))) {
    Write-Host "$($ed[0]) settings"
    foreach ($n in 'settings.json', 'keybindings.json', 'mcp.json', 'snippets') { Copy-NoOverwrite (Join-Path $pc "$($ed[0])\$n") (Join-Path $ed[1] $n) }
    $list = Join-Path $pc "$($ed[0])-extensions.txt"
    if ($InstallExtensions -and (Test-Path -LiteralPath $list) -and (Get-Command $ed[2] -ErrorAction SilentlyContinue)) {
        $installed = @(& $ed[2] --list-extensions 2>$null)
        foreach ($line in Get-Content -LiteralPath $list) {
            $id = ($line -split '@')[0].Trim()
            if (-not $id -or $installed -contains $id) { continue }
            if ($PSCmdlet.ShouldProcess($id, "$($ed[2]) --install-extension")) { & $ed[2] --install-extension $id 2>&1 | Out-Null; Write-Host "  [ext] $id" }
        }
    }
}

if ($PullOllamaModels) {
    $om = Join-Path $BackupRoot '00_MANIFEST\AI-MIGRATION-WORK\01_MANIFESTS\ollama-models.json'
    if ((Test-Path -LiteralPath $om) -and (Get-Command ollama -ErrorAction SilentlyContinue)) {
        $have = (& ollama list 2>$null) -join "`n"
        foreach ($mdl in @(Get-Content -LiteralPath $om -Raw | ConvertFrom-Json | Where-Object { $_.Classification -like 'DOWNLOADABLE_STANDARD*' })) {
            if ($have -match [regex]::Escape($mdl.Model)) { continue }
            if ($PSCmdlet.ShouldProcess($mdl.Model, 'ollama pull')) { & ollama pull $mdl.Model }
        }
    }
}
Write-Host ''
Write-Host 'MCP servers: re-add from 18_REPORTS\MCP-INVENTORY.md (claude mcp add ...). Do not copy ~/.claude.json between machines.'
