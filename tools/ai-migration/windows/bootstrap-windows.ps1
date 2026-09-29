<#
.SYNOPSIS
  Phases 29-30 — idempotent Windows workstation bootstrap (friclawd or a fresh PC).
  Installs only what is missing, via winget. Safe to re-run. No secrets.
.EXAMPLE
  pwsh -File .\bootstrap-windows.ps1              # required tools
  pwsh -File .\bootstrap-windows.ps1 -IncludeOptional
  pwsh -File .\bootstrap-windows.ps1 -WhatIf      # show plan only
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$IncludeOptional,
    [string]$ProjectsRoot = (Join-Path $env:USERPROFILE 'Projects')
)
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:USERPROFILE 'AI-RESTORE-LOGS'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("bootstrap-windows-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Log { param($m, $c = 'Gray') $l = "$(Get-Date -Format s) $m"; Write-Host $l -ForegroundColor $c; Add-Content -LiteralPath $log -Value $l }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Log 'winget not found. Install "App Installer" from Microsoft Store, then re-run.' Red; exit 1 }

# name, winget id, probe command, required?
$packages = @(
    @('Git', 'Git.Git', 'git', $true),
    @('GitHub CLI', 'GitHub.cli', 'gh', $true),
    @('Node.js LTS', 'OpenJS.NodeJS.LTS', 'node', $true),
    @('Python 3.12', 'Python.Python.3.12', 'python', $true),
    @('uv', 'astral-sh.uv', 'uv', $true),
    @('PowerShell 7', 'Microsoft.PowerShell', 'pwsh', $true),
    @('VS Code', 'Microsoft.VisualStudioCode', 'code', $true),
    @('Tailscale', 'tailscale.tailscale', 'tailscale', $true),
    @('7-Zip', '7zip.7zip', '7z', $true),
    @('SQLite CLI', 'SQLite.SQLite', 'sqlite3', $true),
    @('Docker Desktop', 'Docker.DockerDesktop', 'docker', $false),
    @('Cursor', 'Anysphere.Cursor', 'cursor', $false),
    @('Ollama', 'Ollama.Ollama', 'ollama', $false),
    @('Claude Desktop', 'Anthropic.Claude', '', $false)
)
foreach ($p in $packages) {
    $name, $id, $probe, $req = $p
    if (-not $req -and -not $IncludeOptional) { continue }
    $present = $false
    if ($probe -and (Get-Command $probe -ErrorAction SilentlyContinue)) { $present = $true }
    if (-not $present) {
        & winget list --id $id -e --accept-source-agreements 2>$null | Out-Null
        $present = ($LASTEXITCODE -eq 0)
    }
    if ($present) { Log "[skip] $name already installed" Green; continue }
    if ($PSCmdlet.ShouldProcess($name, "winget install $id")) {
        Log "[install] $name ($id)" Cyan
        & winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Add-Content -LiteralPath $log
        Log "  exit $LASTEXITCODE"
    }
}

# Refresh PATH for this session so newly installed tools are visible.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

if (Get-Command corepack -ErrorAction SilentlyContinue) {
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('pnpm', 'corepack enable pnpm')) { & corepack enable pnpm 2>&1 | Add-Content -LiteralPath $log; Log '[install] pnpm via corepack' Cyan }
}
# Claude Code — official native installer (https://code.claude.com/docs). Skipped if already present.
if (Get-Command claude -ErrorAction SilentlyContinue) { Log "[skip] Claude Code $((& claude --version) -join '')" Green }
elseif ($PSCmdlet.ShouldProcess('Claude Code', 'native installer')) {
    Log '[install] Claude Code (native installer)' Cyan
    # Official install command from the Claude Code docs; runs only when claude is absent.
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
}
if (Get-Command npm -ErrorAction SilentlyContinue) {
    if (-not (Get-Command wrangler -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('wrangler', 'npm i -g wrangler')) { & npm i -g wrangler 2>&1 | Add-Content -LiteralPath $log; Log '[install] wrangler' Cyan }
}

if (-not (Test-Path -LiteralPath $ProjectsRoot)) { New-Item -ItemType Directory -Path $ProjectsRoot | Out-Null; Log "Created $ProjectsRoot" }

Log 'Next (manual, never automated): tailscale up · gh auth login · claude (sign in) · wrangler login · Docker Desktop first start.' Yellow
Log "Log: $log" Green
