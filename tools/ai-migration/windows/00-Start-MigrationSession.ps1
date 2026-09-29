<#
.SYNOPSIS
  Phase 0 — create the migration workspace and MIGRATION-SESSION.md. Read-only on the system.
.EXAMPLE
  pwsh -File .\00-Start-MigrationSession.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'AI-MIGRATION-WORK'),
    [string]$ExpectedHostname = 'Bank-Hollenat',
    [string]$ExpectedUser = 'Admin'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MigrationCommon.psm1') -Force

$ws = Get-MigrationWorkspace -Root $WorkspaceRoot
$log = Join-Path $ws.Logs 'phase00-session.log'
Write-MigLog "Workspace: $($ws.Root)" -LogFile $log

# Keep a copy of the toolkit that produced these reports next to them.
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $ws.Scripts -Recurse -Force

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$drives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in 2, 3, 4 } | ForEach-Object {
    [pscustomobject]@{
        Drive  = $_.DeviceID
        Type   = @{ 2 = 'Removable'; 3 = 'Local'; 4 = 'Network' }[[int]$_.DriveType]
        FS     = $_.FileSystem
        Label  = $_.VolumeName
        Total  = Format-Bytes ([double]$_.Size)
        Free   = Format-Bytes ([double]$_.FreeSpace)
    }
}

$tsStatus = 'Tailscale CLI not found'
if (Test-CommandExists 'tailscale') {
    # `tailscale status` lists peer names/IPs only — no keys.
    $tsStatus = (& tailscale status 2>&1 | Out-String).Trim()
}

$warnings = @()
if ($env:COMPUTERNAME -ne $ExpectedHostname) { $warnings += "Hostname is '$($env:COMPUTERNAME)', expected '$ExpectedHostname' — verify you are on the correct source machine." }
if ($env:USERNAME -ne $ExpectedUser) { $warnings += "User is '$($env:USERNAME)', expected '$ExpectedUser'." }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { $warnings += 'Session is elevated (Administrator). The toolkit is designed for normal user rights; elevate only for the specific steps that require it.' }

$md = @"
# MIGRATION SESSION

| Field | Value |
|---|---|
| Start (local) | $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')) |
| Hostname | $($env:COMPUTERNAME) |
| User | $($env:USERNAME) |
| User profile | $($env:USERPROFILE) |
| Windows | $($os.Caption) |
| Version / build | $($os.Version) (build $($os.BuildNumber)) |
| Architecture | $($os.OSArchitecture) |
| Model | $($cs.Manufacturer) $($cs.Model) |
| PowerShell | $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) |
| Elevated | $isAdmin |
| Workspace | $($ws.Root) |

## Drives

$(ConvertTo-MarkdownTable -Rows @($drives) -Columns Drive, Type, FS, Label, Total, Free)

## Tailscale status

``````
$tsStatus
``````

## Warnings

$(if ($warnings.Count) { ($warnings | ForEach-Object { "- $_" }) -join "`n" } else { '- none' })

## Safety contract

- Copy only. No delete / move / reset / uninstall until the user types ``AUTHORIZE_FINAL_CLEANUP_AND_RESET``.
- Secret values are never written to this workspace.
"@
$out = Join-Path $ws.Reports 'MIGRATION-SESSION.md'
Set-Content -LiteralPath $out -Value $md -Encoding UTF8
Write-PhaseStatus -Workspace $ws -Phase 'phase00-session' -Status 'DONE' -Details $warnings -EvidencePath $out
Write-MigLog "Wrote $out" -Level OK -LogFile $log
foreach ($w in $warnings) { Write-MigLog $w -Level WARN -LogFile $log }
