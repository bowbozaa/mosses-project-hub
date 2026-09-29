<#
.SYNOPSIS
  Put two icons on the Windows desktop that launch Run-All.ps1 with a double-click:
    "AI Migration - Test (Dry Run)"  -> plan only, copies nothing
    "AI Migration - Run"             -> real run (still copy-only; asks before copying and for the passphrase)
  Does not overwrite existing shortcuts unless -Force. Needs no admin rights.
.EXAMPLE
  pwsh -File .\Install-DesktopShortcut.ps1
  pwsh -File .\Install-DesktopShortcut.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration' -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DestinationRoot = '\\100.127.194.73\Backup\Mosses-AI-Migration',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$runAll = Join-Path $PSScriptRoot 'Run-All.ps1'
if (-not (Test-Path -LiteralPath $runAll)) { throw "Run-All.ps1 not found next to this script ($PSScriptRoot)" }

# Prefer PowerShell 7 (long paths); fall back to Windows PowerShell 5.1.
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
$shellExe = if ($pwsh) { $pwsh } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$desktop = [Environment]::GetFolderPath('Desktop')   # follows OneDrive-redirected desktops
$wsh = New-Object -ComObject WScript.Shell

$items = @(
    @{ Name = 'AI Migration - Test (Dry Run)'; Extra = '-DryRun'; Desc = 'Shows what would be copied. Copies nothing.' },
    @{ Name = 'AI Migration - Run'; Extra = ''; Desc = 'Copy-only backup to friclawd with SHA-256 verification. Never deletes or resets.' }
)
foreach ($i in $items) {
    $lnk = Join-Path $desktop ($i.Name + '.lnk')
    if ((Test-Path -LiteralPath $lnk) -and -not $Force) { Write-Host "[keep] $lnk exists (use -Force to replace)" -ForegroundColor Yellow; continue }
    if (-not $PSCmdlet.ShouldProcess($lnk, 'create shortcut')) { continue }
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath = $shellExe
    # -NoExit keeps the window open so the summary table stays readable.
    $s.Arguments = ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "{0}" -DestinationRoot "{1}" {2}' -f $runAll, $DestinationRoot, $i.Extra).Trim()
    $s.WorkingDirectory = $PSScriptRoot
    $s.IconLocation = "$shellExe,0"   # the PowerShell icon always exists
    $s.Description = $i.Desc
    $s.Save()
    Write-Host "[new] $lnk" -ForegroundColor Green
}
Write-Host "Destination used by the icons: $DestinationRoot  (re-run with -DestinationRoot ... -Force to change it)"
