<#
.SYNOPSIS
  Phases 2,3,4,7,8,9,18 — discover projects, audit Git source of truth, AI-system candidates,
  skills/agents/prompts, local-only data, database files. Read-only (git runs with --no-optional-locks,
  no fetch, no checkout).
.OUTPUTS
  01_MANIFESTS\PROJECT-INVENTORY.csv, 00_REPORTS\GIT-SOURCE-OF-TRUTH.md, 00_REPORTS\AI-BRAIN-MAP.md,
  00_REPORTS\SKILLS-MANIFEST.md, AGENTS-MANIFEST.md, PROMPTS-MANIFEST.md, DATABASE-INVENTORY.md,
  LOCAL-ONLY-DATA.md, 01_MANIFESTS\migration-sources.json (DRAFT — review before 06-Copy)
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [string[]]$SearchRoots = @($env:USERPROFILE, 'D:\'),
    [int]$MaxDepth = 8
)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase02-projects.log'
$excludeDirs = Get-DefaultExcludeDirs

$SearchRoots = @($SearchRoots | Where-Object { Test-Path -LiteralPath $_ })
Write-MigLog ("Phase 2: scanning {0} (depth {1})" -f ($SearchRoots -join ', '), $MaxDepth) -LogFile $log

$skipWalk = @('AppData', 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin',
    'System Volume Information', '.git', 'OneDriveTemp', 'Recovery', '.cache', '.npm', '.nuget', '.gradle',
    '.rustup', '.cargo', 'scoop', '.pyenv') + $excludeDirs
$markers = @('package.json', 'pyproject.toml', 'requirements.txt', 'Pipfile', 'Dockerfile', 'docker-compose.yml',
    'docker-compose.yaml', 'compose.yml', 'compose.yaml', 'wrangler.toml', 'wrangler.jsonc', 'wrangler.json',
    'vercel.json', 'netlify.toml', '.mcp.json', 'go.mod', 'Cargo.toml', 'uv.lock', 'bun.lock', 'bun.lockb')
$aiRegex = '(?i)(jarvis|j\.a\.r\.v\.i\.s|friday|f\.r\.i\.d\.a\.y|edith|e\.d\.i\.t\.h|flyday|brain|\brag\b|vector|embedding|memory|knowledge|\bmcp\b|mcp[-_]|skills?\b|agents?\b|prompts?\b|hooks\b|n8n|claw|chroma|qdrant|lancedb|faiss|ollama)'
$dbExt = @('.sqlite', '.sqlite3', '.db', '.db3', '.duckdb', '.mdb', '.accdb', '.faiss', '.rdb', '.aof')
$dbNames = @('PG_VERSION', 'dump.rdb', 'appendonly.aof')

$projectDirs = New-Object System.Collections.Generic.List[object]
$aiHits = New-Object System.Collections.Generic.List[object]
$instructionFiles = New-Object System.Collections.Generic.List[object]
$dbFiles = New-Object System.Collections.Generic.List[object]
$walkErrors = New-Object System.Collections.Generic.List[string]

foreach ($root in $SearchRoots) {
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@((New-Object System.IO.DirectoryInfo($root)), 0, $false))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop(); $dir = $item[0]; $depth = $item[1]; $inProject = $item[2]
        try {
            $children = @($dir.EnumerateFileSystemInfos())
        } catch { $walkErrors.Add("$($dir.FullName) :: $($_.Exception.Message)"); continue }
        $names = @($children | ForEach-Object { $_.Name })
        $isGit = $names -contains '.git'
        $hasMarker = @($names | Where-Object { $markers -contains $_ }).Count -gt 0
        $isProject = $false
        if ($isGit -or ($hasMarker -and -not $inProject)) {
            $projectDirs.Add([pscustomobject]@{ Path = $dir.FullName; IsGit = $isGit; Markers = (@($names | Where-Object { $markers -contains $_ }) -join ';') })
            $isProject = $true
        }
        if ($dir.Name -match $aiRegex -and $depth -gt 0) {
            $aiHits.Add([pscustomobject]@{ Kind = 'dir'; Path = $dir.FullName })
        }
        foreach ($c in $children) {
            if ($c -is [System.IO.FileInfo]) {
                $n = $c.Name
                $parent = $c.Directory.Name
                $grand = if ($c.Directory.Parent) { $c.Directory.Parent.Name } else { '' }
                $kind = $null
                if ($n -eq 'SKILL.md') { $kind = 'skill' }
                elseif ($n -in @('CLAUDE.md', 'AGENTS.md', 'GEMINI.md', '.cursorrules', 'copilot-instructions.md')) { $kind = 'instructions' }
                elseif ($c.Extension -eq '.md' -and $parent -eq 'agents') { $kind = 'agent' }
                elseif ($c.Extension -eq '.md' -and $parent -eq 'commands') { $kind = 'command' }
                elseif ($parent -eq 'hooks' -and $grand -eq '.claude') { $kind = 'hook' }
                elseif ($parent -eq 'rules' -and $grand -eq '.cursor') { $kind = 'cursor-rule' }
                elseif ($n -match '(?i)(system[-_ ]?prompt|prompt).*\.(md|txt|ya?ml|json)$') { $kind = 'prompt' }
                if ($kind) { $instructionFiles.Add([pscustomobject]@{ Kind = $kind; Name = $n; Path = $c.FullName; Length = $c.Length }) }
                if (($dbExt -contains $c.Extension.ToLowerInvariant()) -or ($dbNames -contains $n)) {
                    $dbFiles.Add([pscustomobject]@{ Path = $c.FullName; Size = $c.Length; LastWrite = $c.LastWriteTime })
                }
                if ($n -match $aiRegex -and $c.Extension -in @('.md', '.json', '.yaml', '.yml', '.toml', '.txt', '.py', '.ts', '.js')) {
                    if ($aiHits.Count -lt 3000) { $aiHits.Add([pscustomobject]@{ Kind = 'file'; Path = $c.FullName }) }
                }
            } elseif ($depth -lt $MaxDepth) {
                if ($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($skipWalk -contains $c.Name) { continue }
                $stack.Push(@([System.IO.DirectoryInfo]$c, ($depth + 1), ($inProject -or $isProject)))
            }
        }
    }
}
Write-MigLog ("Found {0} project roots, {1} AI-related paths, {2} instruction files, {3} database files" -f $projectDirs.Count, $aiHits.Count, $instructionFiles.Count, $dbFiles.Count) -Level OK -LogFile $log

# ---------------------------------------------------------------------------
# Git audit (read-only)
# ---------------------------------------------------------------------------
$gitAvailable = Test-CommandExists 'git'
$inventory = foreach ($p in $projectDirs) {
    Write-MigLog "Auditing $($p.Path)" -LogFile $log
    $size = Get-DirectorySizeBytes -Path $p.Path -ExcludeDirs $excludeDirs
    $row = [ordered]@{
        'Project Name' = Split-Path $p.Path -Leaf; 'Absolute Path' = $p.Path; 'Drive' = $p.Path.Substring(0, 2)
        'Approx Size' = Format-Bytes $size; 'SizeBytes' = $size; 'Git?' = $p.IsGit; 'Remote URL' = ''
        'Current Branch' = ''; 'HEAD Commit' = ''; 'Dirty?' = ''; 'Untracked Files?' = ''; 'Ignored Local Files' = ''
        'Unpushed Commits?' = ''; 'Stashes' = ''; 'Submodules' = ''; 'LFS' = ''; 'Runtime' = ''; 'Database' = ''
        'External Services' = ''; 'Classification' = ''; 'Backup Priority' = ''; 'Restore Priority' = ''
        'Recommended Destination' = ''; 'Notes' = ''
    }
    # runtime / service hints from markers
    $rt = @()
    if ($p.Markers -match 'package.json|bun.lock') { $rt += 'Node' }
    if ($p.Markers -match 'pyproject|requirements|Pipfile|uv.lock') { $rt += 'Python' }
    if ($p.Markers -match 'go.mod') { $rt += 'Go' }
    if ($p.Markers -match 'Cargo') { $rt += 'Rust' }
    if ($p.Markers -match 'Dockerfile|compose') { $rt += 'Docker' }
    $row['Runtime'] = $rt -join ','
    $svc = @()
    if ($p.Markers -match 'wrangler') { $svc += 'Cloudflare' }
    if ($p.Markers -match 'vercel') { $svc += 'Vercel' }
    if ($p.Markers -match 'netlify') { $svc += 'Netlify' }
    if (Test-Path -LiteralPath (Join-Path $p.Path 'supabase')) { $svc += 'Supabase' }
    if ($p.Markers -match '\.mcp\.json') { $svc += 'MCP' }
    $row['External Services'] = $svc -join ','
    $row['Database'] = (@($dbFiles | Where-Object { $_.Path.StartsWith($p.Path + '\') }).Count)

    $notes = @()
    if ($p.IsGit -and $gitAvailable) {
        $remotes = @(Invoke-GitRead $p.Path @('remote', '-v') | ForEach-Object { Protect-Text $_ })
        $row['Remote URL'] = (@($remotes | Where-Object { $_ -match '\(fetch\)' } | ForEach-Object { ($_ -split '\s+')[1] }) -join ' ; ')
        $row['Current Branch'] = (Invoke-GitRead $p.Path @('rev-parse', '--abbrev-ref', 'HEAD')) -join ''
        $row['HEAD Commit'] = (Invoke-GitRead $p.Path @('rev-parse', 'HEAD')) -join ''
        $status = @(Invoke-GitRead $p.Path @('status', '--porcelain=v1'))
        $tracked = @($status | Where-Object { $_ -and -not $_.StartsWith('??') }).Count
        $untracked = @($status | Where-Object { $_ -and $_.StartsWith('??') }).Count
        $ignored = @(Invoke-GitRead $p.Path @('status', '--porcelain=v1', '--ignored=matching') | Where-Object { $_ -and $_.StartsWith('!!') } |
            Where-Object { $line = $_; -not (@($excludeDirs | Where-Object { $line -match ('(^|/)' + [regex]::Escape($_) + '(/|$)') }).Count) })
        $row['Dirty?'] = $tracked; $row['Untracked Files?'] = $untracked; $row['Ignored Local Files'] = $ignored.Count
        # Commits on any local branch that are on no remote-tracking ref (as of the last fetch — no fetch is run).
        $unpushed = (Invoke-GitRead $p.Path @('rev-list', '--count', '--branches', '--not', '--remotes')) -join ''
        $row['Unpushed Commits?'] = $unpushed
        $row['Stashes'] = @(Invoke-GitRead $p.Path @('stash', 'list')).Count
        $row['Submodules'] = Test-Path -LiteralPath (Join-Path $p.Path '.gitmodules')
        $ga = Join-Path $p.Path '.gitattributes'
        $row['LFS'] = (Test-Path -LiteralPath $ga) -and ((Get-Content -LiteralPath $ga -Raw -ErrorAction SilentlyContinue) -match 'filter=lfs')
        if ($ignored.Count -gt 0) { $notes += ('ignored-local: ' + ((@($ignored | Select-Object -First 5) | ForEach-Object { $_.Substring(3) }) -join ', ')) }
        $clean = ($tracked -eq 0 -and $untracked -eq 0 -and "$unpushed" -eq '0' -and $row['Stashes'] -eq 0)
        if (-not $row['Remote URL']) { $cls = 'LOCAL_UNIQUE'; $prio = 'CRITICAL'; $notes += 'no remote' }
        elseif ($clean -and $ignored.Count -eq 0) { $cls = 'REMOTE_SOURCE_OF_TRUTH'; $prio = 'MEDIUM' }
        else { $cls = 'LOCAL_UNIQUE'; $prio = 'CRITICAL'; $notes += 'local changes/commits/ignored files not on remote' }
    } elseif ($p.IsGit) {
        $cls = 'UNKNOWN'; $prio = 'CRITICAL'; $notes += 'git not installed — cannot audit'
    } else {
        $cls = 'LOCAL_UNIQUE'; $prio = 'HIGH'; $notes += 'not a git repo — no remote copy'
    }
    if ($p.Path -match '(?i)archive|backup') { $cls = 'ARCHIVE'; if ($prio -eq 'MEDIUM') { $prio = 'HIGH' }; $notes += 'archive/backup location — audit contents, do not assume redundant' }
    $row['Classification'] = $cls; $row['Backup Priority'] = $prio
    $row['Restore Priority'] = if ($prio -eq 'CRITICAL') { 'HIGH' } else { 'MEDIUM' }
    $row['Recommended Destination'] = if ($cls -eq 'ARCHIVE') { '16_ARCHIVE' } else { '01_PROJECTS' }
    $row['Notes'] = $notes -join ' | '
    [pscustomobject]$row
}
$inventory = @($inventory)

# Duplicate detection: same normalized remote URL in more than one folder. KEEP BOTH.
$norm = { param($u) ($u -replace '\.git$', '' -replace '^git@github\.com:', 'https://github.com/' -replace '<REDACTED>@', '').ToLowerInvariant().TrimEnd('/') }
$groups = $inventory | Where-Object { $_.'Remote URL' } | Group-Object { & $norm (($_.'Remote URL' -split ' ; ')[0]) } | Where-Object { $_.Count -gt 1 }
$dupSections = foreach ($g in $groups) {
    $heads = @($g.Group | ForEach-Object { $_.'HEAD Commit' } | Select-Object -Unique)
    foreach ($r in $g.Group) {
        $others = ($g.Group | Where-Object { $_ -ne $r } | ForEach-Object { $_.'Absolute Path' }) -join '; '
        $r.Notes = ($r.Notes + " | DUPLICATE_CANDIDATE of: $others" + $(if ($heads.Count -gt 1) { ' (HEAD differs — keep both)' } else { ' (same HEAD — compare working trees before treating as duplicate)' })).Trim(' |')
    }
    "### $($g.Name)`n`n" + (ConvertTo-MarkdownTable -Rows @($g.Group) -Columns 'Absolute Path', 'Current Branch', 'HEAD Commit', 'Dirty?', 'Untracked Files?', 'Unpushed Commits?', 'Stashes')
}

$csv = Join-Path $ws.Manifests 'PROJECT-INVENTORY.csv'
$inventory | Select-Object * -ExcludeProperty SizeBytes | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$gitRows = @($inventory | Where-Object { $_.'Git?' })
$atRisk = @($gitRows | Where-Object { $_.Classification -ne 'REMOTE_SOURCE_OF_TRUTH' })
$gitMd = @"
# GIT SOURCE OF TRUTH

Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Read-only audit: no fetch, no checkout, no reset.
"Unpushed" = commits on local branches not present on any remote-tracking ref as of the LAST fetch.

- Git repositories: $($gitRows.Count)
- Repositories with data NOT on the remote: **$($atRisk.Count)** (bundled by 05-Prepare-LocalBackups.ps1)

## Repositories needing preservation

$(ConvertTo-MarkdownTable -Rows $atRisk -Columns 'Absolute Path', 'Remote URL', 'Current Branch', 'Dirty?', 'Untracked Files?', 'Ignored Local Files', 'Unpushed Commits?', 'Stashes', 'Notes')

## Duplicate candidates (never merged automatically)

$(if ($dupSections) { $dupSections -join "`n`n" } else { 'none' })

## All repositories

$(ConvertTo-MarkdownTable -Rows $gitRows -Columns 'Absolute Path', 'Current Branch', 'HEAD Commit', 'Classification', 'Submodules', 'LFS')
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'GIT-SOURCE-OF-TRUTH.md') -Value $gitMd -Encoding UTF8

# Local-only data (Phase 9)
$localOnly = @($inventory | Where-Object { $_.Classification -in 'LOCAL_UNIQUE', 'UNKNOWN', 'ARCHIVE' -or [int]("0$($_.'Ignored Local Files')") -gt 0 })
$lo = @"
# LOCAL-ONLY DATA (GitHub cannot recover these)

$(ConvertTo-MarkdownTable -Rows $localOnly -Columns 'Absolute Path', 'Classification', 'Backup Priority', 'Dirty?', 'Untracked Files?', 'Ignored Local Files', 'Database', 'Notes')

Secret files (.env etc.) inside these folders are excluded from the plain copy and go to the encrypted archive (08).
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'LOCAL-ONLY-DATA.md') -Value $lo -Encoding UTF8

# ---------------------------------------------------------------------------
# Skills / agents / prompts (canonical detection by content hash)
# ---------------------------------------------------------------------------
$instr = foreach ($f in $instructionFiles) {
    $h = try { (Get-FileHash -LiteralPath $f.Path -Algorithm SHA256).Hash.Substring(0, 12) } catch { 'ERR' }
    $label = if ($f.Kind -eq 'skill') { Split-Path (Split-Path $f.Path -Parent) -Leaf } else { $f.Name }
    [pscustomobject]@{ Kind = $f.Kind; Name = $label; Path = $f.Path; Size = Format-Bytes $f.Length; Hash12 = $h; Copies = 0; Canonical = '' }
}
$instr = @($instr)
foreach ($g in ($instr | Group-Object Kind, Name)) {
    $distinct = @($g.Group | Select-Object -ExpandProperty Hash12 -Unique)
    foreach ($r in $g.Group) {
        $r.Copies = $g.Count
        $r.Canonical = if ($g.Count -eq 1) { 'single copy' } elseif ($distinct.Count -eq 1) { 'identical copies' } else { 'DIFFERENT versions — choose canonical manually, keep all' }
    }
}
$writeManifest = {
    param($file, $title, $kinds)
    $rows = @($instr | Where-Object { $kinds -contains $_.Kind } | Sort-Object Name, Path)
    $body = "# $title`n`nGenerated: $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Duplicates are kept until a canonical copy is chosen.`n`nTotal: $($rows.Count)`n`n" +
        (ConvertTo-MarkdownTable -Rows $rows -Columns Kind, Name, Copies, Canonical, Hash12, Size, Path)
    Set-Content -LiteralPath (Join-Path $ws.Reports $file) -Value $body -Encoding UTF8
}
& $writeManifest 'SKILLS-MANIFEST.md' 'SKILLS MANIFEST' @('skill')
& $writeManifest 'AGENTS-MANIFEST.md' 'AGENTS MANIFEST' @('agent', 'command', 'hook')
& $writeManifest 'PROMPTS-MANIFEST.md' 'PROMPTS / INSTRUCTIONS MANIFEST' @('instructions', 'prompt', 'cursor-rule')

# ---------------------------------------------------------------------------
# Databases (Phase 18)
# ---------------------------------------------------------------------------
$dbRows = foreach ($d in $dbFiles) {
    $engine = switch -Regex ($d.Path) {
        '\.(sqlite3?|db3?)$' { 'SQLite (verify)'; break }
        '\.duckdb$' { 'DuckDB'; break }
        'PG_VERSION$' { 'PostgreSQL data dir'; break }
        '\.(rdb|aof)$|dump\.rdb|appendonly' { 'Redis persistence'; break }
        '\.faiss$' { 'FAISS index'; break }
        default { 'Other' }
    }
    $proj = ($inventory | Where-Object { $d.Path.StartsWith($_.'Absolute Path' + '\') } | Sort-Object { $_.'Absolute Path'.Length } -Descending | Select-Object -First 1).'Absolute Path'
    $strategy = switch -Regex ($engine) {
        'SQLite' { 'sqlite3 .backup (05) — consistent even if app running; raw copy also taken'; break }
        'PostgreSQL' { 'pg_dump from running server (manual) + raw copy only when server stopped'; break }
        'Redis' { 'copy after BGSAVE / server stopped'; break }
        default { 'raw copy' }
    }
    [pscustomobject]@{ Path = $d.Path; Engine = $engine; Size = Format-Bytes $d.Size; LastWrite = $d.LastWrite; Project = $proj; Backup = $strategy }
}
$dbMd = @"
# DATABASE INVENTORY

$(ConvertTo-MarkdownTable -Rows @($dbRows) -Columns Path, Engine, Size, LastWrite, Project, Backup)

Remote databases (not on this notebook — back up from the service itself):
- Flyday Brain: Cloudflare D1 ``friclawd-db`` + Vectorize ``flyday-brain-vectors`` (05-Prepare-LocalBackups.ps1 -ExportBrainD1)
- Supabase projects: use Supabase dashboard backups / ``supabase db dump``
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'DATABASE-INVENTORY.md') -Value $dbMd -Encoding UTF8
$dbRows | Export-Csv -LiteralPath (Join-Path $ws.Manifests 'database-files.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# AI brain map candidates (Phase 4) — classification needs human/Claude review
# ---------------------------------------------------------------------------
$aiRows = foreach ($h in ($aiHits | Sort-Object Path -Unique)) {
    $system = switch -Regex ($h.Path) {
        '(?i)jarvis|j\.a\.r\.v\.i\.s' { 'J.A.R.V.I.S.'; break }
        '(?i)friday|f\.r\.i\.d\.a\.y' { 'F.R.I.D.A.Y.'; break }
        '(?i)edith|e\.d\.i\.t\.h' { 'E.D.I.T.H.'; break }
        '(?i)flyday' { 'Flyday Brain'; break }
        '(?i)brain|memory|knowledge|rag|vector|embedding|chroma|qdrant|lancedb|faiss' { 'Brain/RAG/Memory'; break }
        '(?i)mcp' { 'MCP'; break }
        '(?i)skill' { 'Skills'; break }
        '(?i)agent|claw' { 'Agents'; break }
        '(?i)prompt' { 'Prompts'; break }
        '(?i)n8n' { 'n8n'; break }
        '(?i)ollama' { 'Ollama'; break }
        default { 'Other AI' }
    }
    $cov = ($inventory | Where-Object { $h.Path -eq $_.'Absolute Path' -or $h.Path.StartsWith($_.'Absolute Path' + '\') } | Select-Object -First 1)
    [pscustomobject]@{ System = $system; Kind = $h.Kind; Path = $h.Path; InProject = if ($cov) { $cov.'Absolute Path' } else { 'NOT INSIDE A DETECTED PROJECT' }; Role = 'UNKNOWN (review)' }
}
$aiRows = @($aiRows)
$sections = foreach ($g in ($aiRows | Group-Object System | Sort-Object Name)) {
    "## $($g.Name) ($($g.Count))`n`n" + (ConvertTo-MarkdownTable -Rows @($g.Group | Select-Object -First 200) -Columns Kind, Path, InProject, Role)
}
$aiMd = @"
# AI BRAIN MAP (candidates)

Generated by keyword scan. **Role = UNKNOWN until reviewed** — fill in SOURCE_OF_TRUTH / LOCAL_COPY / REMOTE_COPY /
CACHE / GENERATED / DATABASE / CONFIGURATION, plus credential, startup and restore procedure per component.

Known remote source of truth (verified from the flyday-brain-mcp repo):
- Flyday Brain data = Cloudflare D1 ``friclawd-db`` + Vectorize ``flyday-brain-vectors`` behind ``flyday-brain-api``.
  The notebook holds code copies only, unless this scan finds local data stores.
- ChatGPT / Claude account memory is cloud-side — verify by signing in on another device, not by copying files.

Paths NOT INSIDE A DETECTED PROJECT need an explicit decision in migration-sources.json.

$($sections -join "`n`n")
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'AI-BRAIN-MAP.md') -Value $aiMd -Encoding UTF8

# ---------------------------------------------------------------------------
# Draft copy sources (reviewed by a human/Claude before 06-Copy-ToDestination.ps1)
# ---------------------------------------------------------------------------
$userProfile = $env:USERPROFILE.TrimEnd('\')
$tops = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($r in $inventory) {
    $pth = $r.'Absolute Path'
    if ($pth.StartsWith($userProfile + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $pth.Substring($userProfile.Length + 1).Split('\')[0]
        [void]$tops.Add((Join-Path $userProfile $rel))
    } else {
        $seg = $pth.Split('\')
        if ($seg.Count -ge 2 -and $seg[1]) { [void]$tops.Add(($seg[0] + '\' + $seg[1])) }
    }
}
$sources = New-Object System.Collections.Generic.List[object]
foreach ($t in ($tops | Sort-Object)) {
    if ($t -ieq $userProfile) { continue }
    $leaf = Split-Path $t -Leaf
    $drv = $t.Substring(0, 1)
    $dest = if ($t -match '(?i)archive') { "16_ARCHIVE\$drv`_$leaf" } else { "01_PROJECTS\$drv`_$leaf" }
    $sources.Add([ordered]@{ name = "$drv`_$leaf"; path = $t; destination = $dest; include = $true; reason = 'contains detected project(s)' })
}
$extra = @(
    @('.claude', '07_CLAUDE\dot-claude', $true, 'Claude Code global config/skills/agents (credentials excluded automatically)'),
    @('.cursor', '15_VSCODE_CURSOR\dot-cursor', $true, 'Cursor rules/MCP (extensions dir excluded by 06)'),
    @('.n8n', '08_N8N\dot-n8n', $true, 'local n8n data (config with encryptionKey goes to encrypted archive)'),
    @('.codex', '14_CONFIG\dot-codex', $true, 'Codex CLI config'),
    @('.gemini', '14_CONFIG\dot-gemini', $true, 'Gemini CLI config'),
    @('.agents', '05_AGENTS\dot-agents', $true, 'agent definitions'),
    @('.ollama', '14_CONFIG\dot-ollama', $false, 'standard models are re-downloadable — enable only if 04 reports CUSTOM_MODEL'),
    @('Documents', '14_CONFIG\Documents', $false, 'user documents — decide explicitly'),
    @('Desktop', '14_CONFIG\Desktop', $false, 'user desktop — decide explicitly'),
    @('Downloads', '14_CONFIG\Downloads', $false, 'downloads — decide explicitly')
)
foreach ($e in $extra) {
    $p = Join-Path $userProfile $e[0]
    if ((Test-Path -LiteralPath $p) -and -not ($sources | Where-Object { $_.path -ieq $p })) {
        $sources.Add([ordered]@{ name = $e[0].TrimStart('.'); path = $p; destination = $e[1]; include = $e[2]; reason = $e[3] })
    } elseif ($sources | Where-Object { $_.path -ieq $p }) {
        ($sources | Where-Object { $_.path -ieq $p }) | ForEach-Object { $_.destination = $e[1]; $_.reason = $e[3] }
    }
}
foreach ($s in $sources) {
    if (Test-Path -LiteralPath $s.path) { $s.sizeBytes = Get-DirectorySizeBytes -Path $s.path -ExcludeDirs $excludeDirs; $s.size = Format-Bytes $s.sizeBytes }
}
$srcFile = Join-Path $ws.Manifests 'migration-sources.json'
[ordered]@{
    note          = 'DRAFT generated by 02-Discover-Projects.ps1. Review include flags before running 06-Copy-ToDestination.ps1.'
    excludeDirs   = $excludeDirs
    secretPattern = Get-SecretFilePatterns
    sources       = $sources
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $srcFile -Encoding UTF8

if ($walkErrors.Count) { $walkErrors | Set-Content -LiteralPath (Join-Path $ws.Logs 'phase02-access-errors.log') -Encoding UTF8 }
$det = @("projects=$($inventory.Count)", "at_risk_git=$($atRisk.Count)", "access_errors=$($walkErrors.Count)")
Write-PhaseStatus -Workspace $ws -Phase 'phase02-projects' -Status 'DONE' -Details $det -EvidencePath $csv
Write-MigLog "Phase 2 complete. Review $srcFile before copying." -Level OK -LogFile $log
