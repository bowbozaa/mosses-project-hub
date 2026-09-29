<#
.SYNOPSIS
  Phases 5,6,10,12,13,14,15 — Claude, MCP, secret dependency map (names only), SSH/Git identity,
  VS Code, Cursor, n8n. Read-only. Never prints secret values.
.OUTPUTS
  00_REPORTS\CLAUDE-INVENTORY.md, MCP-INVENTORY.md, SECRET-DEPENDENCY-MAP.md, GIT-SSH-INVENTORY.md,
  VSCODE-INVENTORY.md, CURSOR-INVENTORY.md, N8N-MIGRATION.md; 01_MANIFESTS\mcp-servers.json,
  01_MANIFESTS\secret-files.txt (paths only), 01_MANIFESTS\vscode-extensions.txt, cursor-extensions.txt
#>
[CmdletBinding()]
param([string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'))
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase03-config.log'
$up = $env:USERPROFILE
$inventoryCsv = Join-Path $ws.Manifests 'PROJECT-INVENTORY.csv'
$projects = @()
if (Test-Path $inventoryCsv) { $projects = @(Import-Csv $inventoryCsv) } else { Write-MigLog 'PROJECT-INVENTORY.csv missing — run 02 first for project-level MCP/.env coverage' -Level WARN -LogFile $log }

function Read-JsonLoose {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch {
            # JSONC: strip // and /* */ comments outside of strings (best effort) and trailing commas.
            $noBlock = [regex]::Replace($raw, '/\*.*?\*/', '', 'Singleline')
            $noLine = [regex]::Replace($noBlock, '(?m)^\s*//.*$', '')
            $noTrail = [regex]::Replace($noLine, ',\s*([\]}])', '$1')
            return ($noTrail | ConvertFrom-Json -ErrorAction Stop)
        }
    } catch { return $null }
}
function Get-Props { param($o) if ($null -eq $o) { return @() } return @($o.PSObject.Properties) }

# ---------------------------------------------------------------------------
# Claude Code / Claude Desktop (Phase 5)
# ---------------------------------------------------------------------------
$claudeDir = Join-Path $up '.claude'
$claudeClass = @{
    'settings.json' = 'GLOBAL_CONFIG'; 'settings.local.json' = 'GLOBAL_CONFIG (machine-local)'; 'CLAUDE.md' = 'GLOBAL_CONFIG'
    'commands' = 'PORTABLE'; 'agents' = 'PORTABLE'; 'skills' = 'PORTABLE'; 'hooks' = 'PORTABLE'; 'output-styles' = 'PORTABLE'
    'plugins' = 'PORTABLE (reinstall from marketplace preferred)'; 'keybindings.json' = 'PORTABLE'
    '.credentials.json' = 'AUTHENTICATION (never copied — re-login on destination)'
    'projects' = 'MACHINE_SPECIFIC (session history, keyed by Windows path)'; 'todos' = 'CACHE'; 'shell-snapshots' = 'CACHE'
    'statsig' = 'CACHE'; 'ide' = 'MACHINE_SPECIFIC'; 'cache' = 'CACHE'; 'debug' = 'CACHE'; 'file-history' = 'CACHE'
    'session-env' = 'CACHE'; 'telemetry' = 'CACHE'; 'history.jsonl' = 'MACHINE_SPECIFIC (prompt history)'; 'memory' = 'PORTABLE (review)'
}
$claudeRows = @()
if (Test-Path -LiteralPath $claudeDir) {
    $claudeRows = foreach ($i in Get-ChildItem -LiteralPath $claudeDir -Force -ErrorAction SilentlyContinue) {
        $sz = if ($i.PSIsContainer) { Get-DirectorySizeBytes -Path $i.FullName } else { $i.Length }
        [pscustomobject]@{ Item = $i.Name; Type = if ($i.PSIsContainer) { 'dir' } else { 'file' }; Size = Format-Bytes $sz; Class = if ($claudeClass.ContainsKey($i.Name)) { $claudeClass[$i.Name] } else { 'UNKNOWN (review)' } }
    }
}
$claudeJson = Join-Path $up '.claude.json'
$desktopCfg = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
$projectClaude = @($projects | Where-Object { Test-Path -LiteralPath (Join-Path $_.'Absolute Path' '.claude') } | ForEach-Object {
        $pc = Join-Path $_.'Absolute Path' '.claude'
        [pscustomobject]@{ Project = $_.'Absolute Path'; Contents = ((Get-ChildItem -LiteralPath $pc -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '); Class = 'PROJECT_CONFIG' }
    })
$claudeMd = @"
# CLAUDE INVENTORY

## Global ``$claudeDir``

$(ConvertTo-MarkdownTable -Rows @($claudeRows) -Columns Item, Type, Size, Class)

## Other Claude files

| File | Exists | Class | Restore |
|---|---|---|---|
| ``$claudeJson`` | $(Test-Path -LiteralPath $claudeJson) | MACHINE_SPECIFIC + AUTHENTICATION (account/OAuth state, per-project MCP) | Do NOT copy. Re-login, re-add MCP from MCP-INVENTORY.md |
| ``$desktopCfg`` | $(Test-Path -LiteralPath $desktopCfg) | GLOBAL_CONFIG (Claude Desktop MCP servers) | Rebuild per OS from MCP-INVENTORY.md (paths differ) |

## Project-level ``.claude`` directories ($($projectClaude.Count))

$(ConvertTo-MarkdownTable -Rows $projectClaude -Columns Project, Contents, Class)

## Restore rule

- PORTABLE / GLOBAL_CONFIG: restored by ``restore-config-windows.ps1`` / ``restore-config-macos.sh`` (never overwrites existing files).
- AUTHENTICATION: run ``claude`` and sign in again on each destination.
- MACHINE_SPECIFIC / CACHE: backed up with ``.claude`` for reference only; not restored automatically.
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'CLAUDE-INVENTORY.md') -Value $claudeMd -Encoding UTF8

# ---------------------------------------------------------------------------
# MCP (Phase 6)
# ---------------------------------------------------------------------------
$mcpSources = New-Object System.Collections.Generic.List[object]
$mcpSources.Add(@($desktopCfg, 'Claude Desktop', 'global'))
$mcpSources.Add(@((Join-Path $env:APPDATA 'Code\User\mcp.json'), 'VS Code', 'global'))
$mcpSources.Add(@((Join-Path $env:APPDATA 'Code\User\settings.json'), 'VS Code (settings.mcp)', 'global'))
$mcpSources.Add(@((Join-Path $up '.cursor\mcp.json'), 'Cursor', 'global'))
$mcpSources.Add(@((Join-Path $env:APPDATA 'Cursor\User\settings.json'), 'Cursor (settings.mcp)', 'global'))
$mcpSources.Add(@((Join-Path $up '.codeium\windsurf\mcp_config.json'), 'Windsurf', 'global'))
$mcpSources.Add(@((Join-Path $up '.gemini\settings.json'), 'Gemini CLI', 'global'))
foreach ($p in $projects) {
    foreach ($rel in @('.mcp.json', '.cursor\mcp.json', '.vscode\mcp.json')) {
        $mcpSources.Add(@((Join-Path $p.'Absolute Path' $rel), "project:$rel", 'project'))
    }
}
$mcpRows = New-Object System.Collections.Generic.List[object]
$addServers = {
    param($servers, $path, $client, $scope)
    foreach ($s in (Get-Props $servers)) {
        $v = $s.Value
        $cmd = if ($v.PSObject.Properties['command']) { "$($v.command)" } else { '' }
        $url = if ($v.PSObject.Properties['url']) { Protect-Text "$($v.url)" } elseif ($v.PSObject.Properties['serverUrl']) { Protect-Text "$($v.serverUrl)" } else { '' }
        $argsList = if ($v.PSObject.Properties['args']) { @($v.args | ForEach-Object { Protect-Argument "$_" }) } else { @() }
        $envNames = if ($v.PSObject.Properties['env']) { @((Get-Props $v.env) | ForEach-Object { $_.Name }) } else { @() }
        $hdrNames = if ($v.PSObject.Properties['headers']) { @((Get-Props $v.headers) | ForEach-Object { $_.Name }) } else { @() }
        $cwd = if ($v.PSObject.Properties['cwd']) { "$($v.cwd)" } else { '' }
        $transport = if ($v.PSObject.Properties['type']) { "$($v.type)" } elseif ($url) { 'http/sse' } else { 'stdio' }
        $all = ($cmd + ' ' + ($argsList -join ' ') + ' ' + $cwd)
        $machinePath = $all -match '[A-Za-z]:\\|\\Users\\|%USERPROFILE%|%APPDATA%'
        $winOnly = $all -match '\.exe\b|\bcmd(\.exe)?\b|powershell|\.ps1\b|\.bat\b|\.cmd\b'
        $mcpRows.Add([pscustomobject]@{
                Name = $s.Name; Client = $client; Scope = $scope; ConfigPath = $path; Transport = $transport
                Command = $cmd; Args = ($argsList -join ' '); Cwd = $cwd; EnvNames = ($envNames -join ','); HeaderNames = ($hdrNames -join ',')
                Url = $url; Runtime = switch -Regex ($cmd) { 'npx|node|npm' { 'Node' } 'uvx|uv|python|pip' { 'Python' } 'docker' { 'Docker' } default { '' } }
                AuthRequired = [bool]($envNames.Count -or $hdrNames.Count -or $url)
                MachineSpecificPath = $machinePath; WindowsCompatible = $true; MacCompatible = if ($winOnly -or $machinePath) { 'NEEDS_CHANGE' } else { 'LIKELY' }
            })
    }
}
foreach ($src in $mcpSources) {
    $path = $src[0]
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $j = Read-JsonLoose $path
    if ($null -eq $j) { $mcpRows.Add([pscustomobject]@{ Name = '(PARSE_FAILED)'; Client = $src[1]; Scope = $src[2]; ConfigPath = $path; Transport = ''; Command = ''; Args = ''; Cwd = ''; EnvNames = ''; HeaderNames = ''; Url = ''; Runtime = ''; AuthRequired = ''; MachineSpecificPath = ''; WindowsCompatible = ''; MacCompatible = 'REVIEW' }); continue }
    if ($j.PSObject.Properties['mcpServers']) { & $addServers $j.mcpServers $path $src[1] $src[2] }
    if ($j.PSObject.Properties['servers']) { & $addServers $j.servers $path $src[1] $src[2] }
    if ($j.PSObject.Properties['mcp'] -and $j.mcp.PSObject.Properties['servers']) { & $addServers $j.mcp.servers $path $src[1] $src[2] }
}
# ~/.claude.json: user-scope and per-project MCP servers (file itself holds auth state — only server defs are read).
if (Test-Path -LiteralPath $claudeJson) {
    $cj = Read-JsonLoose $claudeJson
    if ($cj) {
        if ($cj.PSObject.Properties['mcpServers']) { & $addServers $cj.mcpServers $claudeJson 'Claude Code' 'user' }
        if ($cj.PSObject.Properties['projects']) {
            foreach ($pp in (Get-Props $cj.projects)) {
                if ($pp.Value.PSObject.Properties['mcpServers']) { & $addServers $pp.Value.mcpServers "$claudeJson :: $($pp.Name)" 'Claude Code' 'local-project' }
            }
        }
    }
}
if (Test-CommandExists 'claude') {
    $cl = & claude mcp list 2>&1 | ForEach-Object { Protect-Text "$_" }
    Set-Content -LiteralPath (Join-Path $ws.Manifests 'claude-mcp-list.txt') -Value $cl -Encoding UTF8
}
$mcpRows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ws.Manifests 'mcp-servers.json') -Encoding UTF8
$mcpMd = @"
# MCP INVENTORY

Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Secret-looking args are masked; env/header values are never read into this report.

Servers found: $($mcpRows.Count) (need macOS change: $(@($mcpRows | Where-Object { $_.MacCompatible -ne 'LIKELY' }).Count))

$(ConvertTo-MarkdownTable -Rows $mcpRows.ToArray() -Columns Name, Client, Scope, Transport, Command, Args, Cwd, EnvNames, HeaderNames, Url, Runtime, MachineSpecificPath, MacCompatible, ConfigPath)

## Restore guidance
- ``stdio`` servers with ``npx``/``uvx`` are portable; only the runtime must be installed.
- Rows with ``MachineSpecificPath=True`` need ``mcp.windows.json`` / ``mcp.macos.json`` variants — never copy ``C:\Users\Admin`` into macOS config.
- Remote servers (e.g. flyday-brain-mcp) need re-authentication (OAuth or bearer token from the encrypted archive).
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'MCP-INVENTORY.md') -Value $mcpMd -Encoding UTF8

# ---------------------------------------------------------------------------
# Secret dependency map (Phase 10) — NAMES ONLY
# ---------------------------------------------------------------------------
$secretRows = New-Object System.Collections.Generic.List[object]
$secretFiles = New-Object System.Collections.Generic.List[string]
foreach ($scope in 'User', 'Machine') {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in $vars.Keys) {
        if (Test-IsSecretVariableName "$k") { $secretRows.Add([pscustomobject]@{ Variable = "$k"; Source = "Windows $scope environment"; Project = '(global)'; Reauth = 'maybe' }) }
    }
}
foreach ($prof in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost, (Join-Path $up 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'), (Join-Path $up 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')) | Select-Object -Unique) {
    if ($prof -and (Test-Path -LiteralPath $prof)) {
        $txt = Get-Content -LiteralPath $prof -Raw
        foreach ($m in [regex]::Matches($txt, '\$env:([A-Za-z_][A-Za-z0-9_]*)\s*=|SetEnvironmentVariable\(\s*[''"]([A-Za-z_][A-Za-z0-9_]*)')) {
            $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            $secretRows.Add([pscustomobject]@{ Variable = $n; Source = "PowerShell profile $prof"; Project = '(global)'; Reauth = 'maybe' })
        }
    }
}
$scanRoots = @($projects | ForEach-Object { $_.'Absolute Path' }) + @((Join-Path $up '.claude'), (Join-Path $up '.n8n'), (Join-Path $up '.cursor'))
foreach ($r in ($scanRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
    foreach ($f in (Get-BackupFileList -Root $r -IncludeSecrets | Where-Object { (Test-IsSecretFileName (Split-Path $_.FullName -Leaf)) -or (Test-IsInSecretDir $_.FullName.Substring($r.Length)) })) {
        if (-not $secretFiles.Contains($f.FullName)) { $secretFiles.Add($f.FullName) }
        $leaf = Split-Path $f.FullName -Leaf
        if ($leaf -like '.env*' -or $leaf -eq '.dev.vars') {
            foreach ($n in (Get-EnvFileVariableNames $f.FullName)) { $secretRows.Add([pscustomobject]@{ Variable = $n; Source = $f.FullName; Project = $r; Reauth = 'maybe' }) }
        } else {
            $secretRows.Add([pscustomobject]@{ Variable = "(file) $leaf"; Source = $f.FullName; Project = $r; Reauth = 'maybe' })
        }
    }
    # docker compose variable references
    foreach ($cf in (Get-ChildItem -LiteralPath $r -Filter '*compose*.y*ml' -File -ErrorAction SilentlyContinue)) {
        $txt = Get-Content -LiteralPath $cf.FullName -Raw
        foreach ($m in [regex]::Matches($txt, '\$\{([A-Za-z_][A-Za-z0-9_]*)')) { $secretRows.Add([pscustomobject]@{ Variable = $m.Groups[1].Value; Source = $cf.FullName; Project = $r; Reauth = 'maybe' }) }
    }
}
foreach ($m in $mcpRows) {
    foreach ($n in ($m.EnvNames -split ',' | Where-Object { $_ })) { $secretRows.Add([pscustomobject]@{ Variable = $n; Source = "MCP $($m.Name) @ $($m.ConfigPath)"; Project = $m.Client; Reauth = 'maybe' }) }
}
# Fixed-location secret files
foreach ($fx in @((Join-Path $up '.n8n\config'), (Join-Path $up '.docker\config.json'), (Join-Path $up '.git-credentials'), (Join-Path $up '.config\gh\hosts.yml'), (Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'), (Join-Path $up '.wrangler\config\default.toml'), (Join-Path $up '.npmrc'))) {
    if ((Test-Path -LiteralPath $fx) -and -not $secretFiles.Contains($fx)) { $secretFiles.Add($fx) }
}
$sshDir = Join-Path $up '.ssh'
if (Test-Path -LiteralPath $sshDir) {
    foreach ($k in Get-ChildItem -LiteralPath $sshDir -File -Force) {
        if ($k.Extension -ne '.pub' -and $k.Name -notin 'known_hosts', 'known_hosts.old', 'config', 'authorized_keys') {
            $first = try { (Get-Content -LiteralPath $k.FullName -TotalCount 1 -ErrorAction Stop) } catch { '' }
            if ($first -match 'PRIVATE KEY') { if (-not $secretFiles.Contains($k.FullName)) { $secretFiles.Add($k.FullName) } }
        }
    }
}
$reauth = @{ 'ANTHROPIC' = 'yes (console)'; 'CLAUDE' = 'yes (claude login)'; 'GITHUB' = 'yes (gh auth login / new PAT)'; 'GH_' = 'yes (gh auth login)'; 'CLOUDFLARE' = 'yes (new API token)'; 'CF_' = 'yes (new API token)'; 'SUPABASE' = 'yes (dashboard)'; 'OPENAI' = 'yes (new key)'; 'GOOGLE' = 'yes (OAuth/console)'; 'GEMINI' = 'yes (new key)'; 'TELEGRAM' = 'yes (BotFather, rotates token)'; 'N8N_ENCRYPTION_KEY' = 'NO — original key required to decrypt n8n credentials'; 'TAILSCALE' = 'yes (tailscale up)' }
foreach ($row in $secretRows) {
    foreach ($k in $reauth.Keys) { if ($row.Variable -match "^$([regex]::Escape($k))") { $row.Reauth = $reauth[$k] } }
}
$secretFiles | Set-Content -LiteralPath (Join-Path $ws.Manifests 'secret-files.txt') -Encoding UTF8
$uniqueSecrets = @($secretRows | Sort-Object Variable, Source -Unique)
$secMd = @"
# SECRET DEPENDENCY MAP (names only — values never read into reports)

Variables/files: $($uniqueSecrets.Count). Secret files to encrypt: $($secretFiles.Count) (list: 01_MANIFESTS\secret-files.txt).

| Variable Name | Source Location | Dependent Project | Destination Requirement | Backup Status | Reauthentication Possible? |
|---|---|---|---|---|---|
$(($uniqueSecrets | ForEach-Object { "| $($_.Variable) | $($_.Source) | $($_.Project) | set on destination | PENDING (08 encrypted archive) | $($_.Reauth) |" }) -join "`n")

Windows User/Machine environment VALUES are not in any file backup. If a value cannot be re-issued
(e.g. N8N_ENCRYPTION_KEY), store it in your password manager before wiping.
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'SECRET-DEPENDENCY-MAP.md') -Value $secMd -Encoding UTF8

# ---------------------------------------------------------------------------
# SSH / Git identity (Phase 12)
# ---------------------------------------------------------------------------
$sshRows = @()
if (Test-Path -LiteralPath $sshDir) {
    $sshRows = foreach ($k in Get-ChildItem -LiteralPath $sshDir -File -Force) {
        $kind = if ($k.Extension -eq '.pub') { 'public key' } elseif ($secretFiles.Contains($k.FullName)) { 'PRIVATE KEY (encrypted backup only)' } else { $k.Name }
        $fp = ''
        if ($k.Extension -eq '.pub' -and (Test-CommandExists 'ssh-keygen')) { $fp = (& ssh-keygen -lf $k.FullName 2>$null) -join '' }
        [pscustomobject]@{ File = $k.Name; Kind = $kind; Fingerprint = $fp; Modified = $k.LastWriteTime }
    }
}
$hosts = @()
$sshCfg = Join-Path $sshDir 'config'
if (Test-Path -LiteralPath $sshCfg) { $hosts = @(Select-String -LiteralPath $sshCfg -Pattern '^\s*Host\s+(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value }) }
$gitCfg = @()
if (Test-CommandExists 'git') {
    $gitCfg = @(& git config --global --list 2>$null | ForEach-Object {
            $kv = $_ -split '=', 2
            if ($kv[0] -match '(?i)token|password|secret|extraheader') { "$($kv[0])=<REDACTED>" } else { Protect-Text $_ }
        })
}
$ghStatus = if (Test-CommandExists 'gh') { (& gh auth status 2>&1 | ForEach-Object { Protect-Text "$_" }) -join "`n" } else { 'gh not installed' }
$gitSshMd = @"
# GIT / SSH INVENTORY

## ~/.ssh

$(ConvertTo-MarkdownTable -Rows @($sshRows) -Columns File, Kind, Fingerprint, Modified)

SSH config Host aliases: $(if ($hosts) { $hosts -join ', ' } else { 'none' })

## git config --global (secrets redacted)

``````
$($gitCfg -join "`n")
``````

## GitHub CLI

``````
$ghStatus
``````

## Restore
- Private keys: restored only from the encrypted archive (99_ENCRYPTED_SECRETS). Or generate new keys and register them on GitHub (recommended).
- Credential helper tokens: re-authenticate (``gh auth login``, Git Credential Manager sign-in).
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'GIT-SSH-INVENTORY.md') -Value $gitSshMd -Encoding UTF8

# ---------------------------------------------------------------------------
# VS Code / Cursor (Phases 13, 14)
# ---------------------------------------------------------------------------
$editorReport = {
    param($label, $cli, $userDir, $dotDir, $outName, $extFile)
    $exts = @()
    if (Test-CommandExists $cli) { $exts = @(& $cli --list-extensions --show-versions 2>$null) }
    $exts | Set-Content -LiteralPath (Join-Path $ws.Manifests $extFile) -Encoding UTF8
    $files = @()
    foreach ($n in 'settings.json', 'keybindings.json', 'mcp.json', 'tasks.json', 'snippets', 'profiles') {
        $p = Join-Path $userDir $n
        if (Test-Path -LiteralPath $p) {
            $flag = ''
            if (-not (Get-Item -LiteralPath $p -Force).PSIsContainer) {
                $j = Read-JsonLoose $p
                if ($j) { $sus = @((Get-Props $j) | Where-Object { Test-IsSecretVariableName $_.Name } | ForEach-Object { $_.Name }); if ($sus) { $flag = 'REVIEW: secret-like keys ' + ($sus -join ',') } }
            }
            $files += [pscustomobject]@{ Item = $n; Path = $p; Note = $flag }
        }
    }
    $rules = @()
    if ($dotDir -and (Test-Path -LiteralPath $dotDir)) { $rules = @(Get-ChildItem -LiteralPath $dotDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'extensions' } | ForEach-Object { $_.Name }) }
    $md = @"
# $label INVENTORY

User config dir: ``$userDir``

$(ConvertTo-MarkdownTable -Rows @($files) -Columns Item, Path, Note)

Home dot-dir ($dotDir) contents (extensions excluded): $(if ($rules) { $rules -join ', ' } else { 'n/a' })

## Extensions ($($exts.Count)) — full list in 01_MANIFESTS\$extFile

$(($exts | ForEach-Object { "- $_" }) -join "`n")

## Restore
``restore-config-windows.ps1`` / ``restore-config-macos.sh`` install extensions from the list and copy settings without overwriting.
Settings Sync may be used in addition, not instead.
"@
    Set-Content -LiteralPath (Join-Path $ws.Reports $outName) -Value $md -Encoding UTF8
}
& $editorReport 'VS CODE' 'code' (Join-Path $env:APPDATA 'Code\User') (Join-Path $up '.vscode') 'VSCODE-INVENTORY.md' 'vscode-extensions.txt'
& $editorReport 'CURSOR' 'cursor' (Join-Path $env:APPDATA 'Cursor\User') (Join-Path $up '.cursor') 'CURSOR-INVENTORY.md' 'cursor-extensions.txt'

# ---------------------------------------------------------------------------
# n8n (Phase 15)
# ---------------------------------------------------------------------------
$n8nDir = Join-Path $up '.n8n'
$n8nItems = @()
if (Test-Path -LiteralPath $n8nDir) {
    $n8nItems = foreach ($i in Get-ChildItem -LiteralPath $n8nDir -Force -ErrorAction SilentlyContinue) {
        $role = switch -Regex ($i.Name) { '^config$' { 'SECRET (contains encryptionKey) → encrypted archive'; break } '\.sqlite' { 'DATABASE (workflows + encrypted credentials)'; break } 'nodes' { 'custom/community nodes'; break } default { '' } }
        [pscustomobject]@{ Item = $i.Name; Size = if ($i.PSIsContainer) { Format-Bytes (Get-DirectorySizeBytes -Path $i.FullName) } else { Format-Bytes $i.Length }; Role = $role }
    }
}
$n8nVer = Get-CommandVersion 'n8n'
$n8nEnv = @($uniqueSecrets | Where-Object { $_.Variable -like 'N8N_*' } | ForEach-Object { "$($_.Variable) ($($_.Source))" })
$n8nMd = @"
# N8N MIGRATION

| Check | Result |
|---|---|
| Local npm n8n | $(if ($n8nVer) { $n8nVer } else { 'not installed' }) |
| ~/.n8n exists | $(Test-Path -LiteralPath $n8nDir) |
| Docker n8n | see DOCKER-MIGRATION.md |
| N8N_* variable names found | $(if ($n8nEnv) { $n8nEnv -join '; ' } else { 'none' }) |

$(ConvertTo-MarkdownTable -Rows @($n8nItems) -Columns Item, Size, Role)

## Encryption key requirement
n8n encrypts stored credentials with the instance encryption key (``encryptionKey`` in ``~/.n8n/config`` or ``N8N_ENCRYPTION_KEY``).
**Restoring database.sqlite without the original key makes every stored credential unusable.** The key file is in the
encrypted archive; confirm the archive (08) before wiping.

## Cloud / remote n8n
If production n8n runs on n8n Cloud or a VPS, the notebook is not its source of truth — export workflows from that
instance separately (``n8n export:workflow --all`` on the server, or the n8n MCP/API).
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'N8N-MIGRATION.md') -Value $n8nMd -Encoding UTF8

Write-PhaseStatus -Workspace $ws -Phase 'phase03-config' -Status 'DONE' -Details @("mcp_servers=$($mcpRows.Count)", "secret_files=$($secretFiles.Count)", "secret_names=$($uniqueSecrets.Count)") -EvidencePath (Join-Path $ws.Reports 'MCP-INVENTORY.md')
Write-MigLog 'Phase 3 complete (Claude, MCP, secrets map, SSH, editors, n8n).' -Level OK -LogFile $log
