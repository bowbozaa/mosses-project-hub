<#
.SYNOPSIS
  Phase 1 + 21 — machine inventory, BitLocker status (no recovery key), software manifest. Read-only.
.OUTPUTS
  00_REPORTS\MACHINE-INVENTORY.md, 01_MANIFESTS\software-manifest.json, 00_REPORTS\software-manifest.md
#>
[CmdletBinding()]
param([string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'))
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force
$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase01-machine.log'
Write-MigLog 'Phase 1: machine inventory' -LogFile $log

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$profiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object {
    [pscustomobject]@{ Path = $_.LocalPath; Loaded = $_.Loaded; LastUse = $_.LastUseTime }
}
$volumes = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in 2, 3, 4 } | ForEach-Object {
    [pscustomobject]@{
        Drive = $_.DeviceID; FS = $_.FileSystem; Label = $_.VolumeName
        Total = Format-Bytes ([double]$_.Size); Free = Format-Bytes ([double]$_.FreeSpace)
        UsedPct = if ($_.Size) { '{0:N0}%' -f ((1 - $_.FreeSpace / $_.Size) * 100) } else { '' }
    }
}

# --- BitLocker: status only. Recovery key material is never queried. ---
$bitlocker = @()
$bitlockerNote = ''
try {
    $bitlocker = Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Mount      = $_.MountPoint
            Protection = "$($_.ProtectionStatus)"
            Status     = "$($_.VolumeStatus)"
            Encrypted  = "$($_.EncryptionPercentage)%"
            Protectors = (($_.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" }) -join ', ')
        }
    }
} catch {
    $bitlockerNote = 'Get-BitLockerVolume needs elevation. To check (status only, no key shown) run in an elevated PowerShell: manage-bde -status. Then confirm the recovery key is saved at https://account.microsoft.com/devices/recoverykey BEFORE any reset.'
    Write-MigLog "BitLocker: $bitlockerNote" -Level WARN -LogFile $log
}

# --- Tool probes ---
$probes = [ordered]@{
    'Git'            = @('git', @('--version'))
    'GitHub CLI'     = @('gh', @('--version'))
    'Git LFS'        = @('git-lfs', @('--version'))
    'Node.js'        = @('node', @('--version'))
    'npm'            = @('npm', @('--version'))
    'pnpm'           = @('pnpm', @('--version'))
    'yarn'           = @('yarn', @('--version'))
    'bun'            = @('bun', @('--version'))
    'Python'         = @('python', @('--version'))
    'py launcher'    = @('py', @('--version'))
    'pip'            = @('pip', @('--version'))
    'pipx'           = @('pipx', @('--version'))
    'uv'             = @('uv', @('--version'))
    'PowerShell 7'   = @('pwsh', @('--version'))
    'WSL'            = @('wsl', @('--version'))
    'Docker'         = @('docker', @('--version'))
    'VS Code'        = @('code', @('--version'))
    'Cursor'         = @('cursor', @('--version'))
    'Claude Code'    = @('claude', @('--version'))
    'n8n'            = @('n8n', @('--version'))
    'Ollama'         = @('ollama', @('--version'))
    'Wrangler'       = @('wrangler', @('--version'))
    'Supabase CLI'   = @('supabase', @('--version'))
    'Vercel CLI'     = @('vercel', @('--version'))
    'Netlify CLI'    = @('netlify', @('--version'))
    'sqlite3'        = @('sqlite3', @('--version'))
    'psql'           = @('psql', @('--version'))
    'Tailscale'      = @('tailscale', @('version'))
    '7-Zip'          = @('7z', @('i'))
    'gpg'            = @('gpg', @('--version'))
    'OpenSSH'        = @('ssh', @('-V'))
    'winget'         = @('winget', @('--version'))
}
$tools = foreach ($k in $probes.Keys) {
    $cmd = $probes[$k][0]; $args2 = $probes[$k][1]
    $v = Get-CommandVersion -Name $cmd -Arguments $args2
    $path = (Get-Command $cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    [pscustomobject]@{ Tool = $k; Command = $cmd; Installed = [bool]$v; Version = if ($v) { $v } else { '' }; Path = $path }
}

# Claude Desktop is a GUI app — detect by install location.
$claudeDesktop = @(
    (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
    (Join-Path $env:LOCALAPPDATA 'Programs\claude'),
    (Join-Path $env:APPDATA 'Claude')
) | Where-Object { Test-Path -LiteralPath $_ }

# --- Installed applications (registry, per-machine + per-user) ---
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -and -not ($_.PSObject.Properties['SystemComponent'] -and $_.SystemComponent -eq 1) } |
    ForEach-Object {
        [pscustomobject]@{
            Name      = $_.DisplayName
            Version   = if ($_.PSObject.Properties['DisplayVersion']) { $_.DisplayVersion } else { '' }
            Publisher = if ($_.PSObject.Properties['Publisher']) { $_.Publisher } else { '' }
        }
    } | Sort-Object Name -Unique

if (Test-CommandExists 'winget') {
    $wingetExport = Join-Path $ws.Manifests 'winget-export.json'
    & winget export -o $wingetExport --accept-source-agreements 2>&1 | Out-Null
    if (Test-Path $wingetExport) { Write-MigLog "winget export -> $wingetExport" -Level OK -LogFile $log }
}

# --- Software manifest with restore classification ---
$classes = @{
    'Git'          = @('REQUIRED', 'CROSS_PLATFORM', 'Git.Git', 'git')
    'GitHub CLI'   = @('REQUIRED', 'CROSS_PLATFORM', 'GitHub.cli', 'gh')
    'Node.js'      = @('REQUIRED', 'CROSS_PLATFORM', 'OpenJS.NodeJS.LTS', 'node')
    'npm'          = @('REQUIRED', 'CROSS_PLATFORM', '(bundled with Node.js)', '(bundled with node)')
    'pnpm'         = @('OPTIONAL', 'CROSS_PLATFORM', '(corepack enable pnpm)', '(corepack enable pnpm)')
    'Python'       = @('REQUIRED', 'CROSS_PLATFORM', 'Python.Python.3.12', 'python@3.12')
    'uv'           = @('REQUIRED', 'CROSS_PLATFORM', 'astral-sh.uv', 'uv')
    'Docker'       = @('OPTIONAL', 'CROSS_PLATFORM', 'Docker.DockerDesktop', 'cask:docker')
    'VS Code'      = @('REQUIRED', 'CROSS_PLATFORM', 'Microsoft.VisualStudioCode', 'cask:visual-studio-code')
    'Cursor'       = @('OPTIONAL', 'CROSS_PLATFORM', 'Anysphere.Cursor', 'cask:cursor')
    'Claude Code'  = @('REQUIRED', 'CROSS_PLATFORM', '(native installer)', '(native installer)')
    'Tailscale'    = @('REQUIRED', 'CROSS_PLATFORM', 'tailscale.tailscale', 'cask:tailscale')
    'n8n'          = @('OPTIONAL', 'CROSS_PLATFORM', '(npm i -g n8n or Docker)', '(npm i -g n8n or Docker)')
    'Ollama'       = @('OPTIONAL', 'CROSS_PLATFORM', 'Ollama.Ollama', 'cask:ollama')
    'Wrangler'     = @('OPTIONAL', 'CROSS_PLATFORM', '(npm i -g wrangler)', '(npm i -g wrangler)')
    'WSL'          = @('OPTIONAL', 'WINDOWS_ONLY', '(wsl --install)', '(not applicable — native Unix)')
    'PowerShell 7' = @('OPTIONAL', 'CROSS_PLATFORM', 'Microsoft.PowerShell', 'cask:powershell')
    '7-Zip'        = @('REQUIRED', 'MACOS_EQUIVALENT', '7zip.7zip', 'sevenzip')
}
$manifest = foreach ($t in $tools) {
    $c = $classes[$t.Tool]
    [pscustomobject]@{
        name         = $t.Tool
        installed    = $t.Installed
        version      = $t.Version
        requirement  = if ($c) { $c[0] } else { 'OPTIONAL' }
        platform     = if ($c) { $c[1] } else { 'UNKNOWN' }
        windowsId    = if ($c) { $c[2] } else { '' }
        macosId      = if ($c) { $c[3] } else { '' }
        restore      = if ($t.Installed) { 'REINSTALL_REQUIRED' } else { 'NOT_INSTALLED_ON_SOURCE' }
    }
}
$manifest += [pscustomobject]@{
    name = 'Claude Desktop'; installed = [bool]$claudeDesktop; version = ''; requirement = 'OPTIONAL'
    platform = 'CROSS_PLATFORM'; windowsId = 'Anthropic.Claude'; macosId = 'cask:claude'
    restore = if ($claudeDesktop) { 'REINSTALL_REQUIRED' } else { 'NOT_INSTALLED_ON_SOURCE' }
}
$manifestJson = Join-Path $ws.Manifests 'software-manifest.json'
[ordered]@{ generated = (Get-Date).ToString('o'); source = $env:COMPUTERNAME; tools = $manifest; installedApps = $apps } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestJson -Encoding UTF8

$swMd = @"
# SOFTWARE MANIFEST — $($env:COMPUTERNAME)

Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))

## Development tools

$(ConvertTo-MarkdownTable -Rows @($manifest) -Columns name, installed, version, requirement, platform, windowsId, macosId, restore)

## Installed applications ($(@($apps).Count))

$(ConvertTo-MarkdownTable -Rows @($apps) -Columns Name, Version, Publisher)
"@
Set-Content -LiteralPath (Join-Path $ws.Reports 'software-manifest.md') -Value $swMd -Encoding UTF8

$md = @"
# MACHINE INVENTORY — $($env:COMPUTERNAME)

Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))

| Field | Value |
|---|---|
| Windows | $($os.Caption) $($os.Version) build $($os.BuildNumber) |
| Architecture | $($os.OSArchitecture) |
| Model | $($cs.Manufacturer) $($cs.Model) |
| CPU | $($cpu.Name) |
| RAM | $(Format-Bytes ([double]$cs.TotalPhysicalMemory)) |
| Claude Desktop paths | $(if ($claudeDesktop) { $claudeDesktop -join '; ' } else { 'not found' }) |

## User profiles

$(ConvertTo-MarkdownTable -Rows @($profiles) -Columns Path, Loaded, LastUse)

## Volumes

$(ConvertTo-MarkdownTable -Rows @($volumes) -Columns Drive, FS, Label, Total, Free, UsedPct)

## BitLocker / device encryption (status only — recovery keys never read)

$(if ($bitlocker) { ConvertTo-MarkdownTable -Rows @($bitlocker) -Columns Mount, Protection, Status, Encrypted, Protectors } else { "STATUS: UNKNOWN — $bitlockerNote" })

## Development tools

$(ConvertTo-MarkdownTable -Rows @($tools) -Columns Tool, Installed, Version, Path)
"@
$out = Join-Path $ws.Reports 'MACHINE-INVENTORY.md'
Set-Content -LiteralPath $out -Value $md -Encoding UTF8
$details = @()
if (-not $bitlocker) { $details += 'BITLOCKER_STATUS_UNKNOWN: needs elevated manage-bde -status' }
Write-PhaseStatus -Workspace $ws -Phase 'phase01-machine' -Status 'DONE' -Details $details -EvidencePath $out
Write-MigLog "Wrote $out, software-manifest.json/.md" -Level OK -LogFile $log
