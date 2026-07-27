<#
.SYNOPSIS
Remove the swipe navigation animation from one or more Firefox installations.

.DESCRIPTION
The Windows counterpart to uninstall.sh. Uses the manifest written by
install.ps1 where one exists, so a file that was already there before installing
is restored rather than deleted. Without a manifest it removes only files
carrying this project's marker, and leaves anything unrecognised alone.

Needs an elevated shell, for the same reason the installer does.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Path,

    # Take every detected installation, and skip the confirmation.
    [switch] $All,

    # Skip the confirmation only.
    [switch] $Force,

    [string[]] $ExtraDirs,

    [switch] $Elevate
)

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here "lib.ps1")

$BackupRoot = $env:SWIPE_BACKUP_ROOT
if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $Here "backups" }

$records = @()
if ($Path -and $Path.Count -gt 0) {
    $candidates = $Path
} else {
    $records = @(Get-SwipeInstall -ExtraDirs $ExtraDirs)
    # Only the installations that actually carry an install are candidates here,
    # which is the same set the selection prompt will offer.
    $candidates = @($records | Where-Object { $_.Installed } | ForEach-Object { $_.Path })
}

# As in install.ps1: what matters is whether the target can be written, not
# whether this shell happens to be elevated -- and the question has to be
# settled before the selection prompt, so that relaunching elevated does not
# mean answering it twice.
$needsElevation = @($candidates | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Container) -and -not (Test-SwipeWritable -Dir $_)
    })
if ($needsElevation.Count -gt 0 -and -not (Test-SwipeAdmin)) {
    if ($Elevate) {
        $argList = Get-SwipeRelaunchArgs -ScriptPath $MyInvocation.MyCommand.Path `
            -All:$All -ExtraDirs $ExtraDirs -Path $Path
        Write-Host "Administrator rights are needed to write into:"
        foreach ($d in $needsElevation) { Write-Host "  $d" }
        Write-Host ""
        Write-Host "Accept the UAC prompt; the uninstall continues in the window it opens."
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList
        exit 0
    }
    Write-Host ""
    Write-Host "Not writable as this user:"
    foreach ($d in $needsElevation) { Write-Host "  $d" }
    Write-Host ""
    Write-Host "Start PowerShell as Administrator and run:"
    Write-Host ""
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Write-Host ""
    Write-Host "Or re-run this with -Elevate to be prompted by UAC."
    Write-Host ""
    exit 1
}

if ($Path -and $Path.Count -gt 0) {
    $selected = $Path
} else {
    $selected = @(Select-SwipeInstall -Mode "uninstall" -MinVersion "" -Records $records -AssumeAll:$All)
    if (-not $selected -or $selected.Count -eq 0) { exit 1 }
}

Write-Host ""
Write-Host "About to remove swipe navigation from:"
foreach ($d in $selected) { Write-Host "  $d" }
Write-Host ""
if (-not $All -and -not $Force) {
    $confirm = Read-Host "Proceed? [y/N]"
    if ($confirm -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "Aborted."
        exit 1
    }
}

# The newest manifest that refers to a given installation. Stamps lead the
# directory name, so sorting by name is sorting by time.
function Find-SwipeManifest {
    param([string] $FfDir)
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return $null }
    $best = $null
    $manifests = Get-ChildItem -LiteralPath $BackupRoot -Filter "manifest.txt" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object FullName
    foreach ($m in $manifests) {
        foreach ($line in (Get-Content -LiteralPath $m.FullName -ErrorAction SilentlyContinue)) {
            if ($line -eq "ff_dir=$FfDir") {
                $best = $m.FullName
                break
            }
        }
    }
    return $best
}

function Uninstall-SwipeOne {
    param([string] $FfDir)

    $cfg = Join-Path $FfDir "mozilla.cfg"
    $pref = Join-Path $FfDir "defaults\pref\local-settings.js"

    if (-not (Test-SwipeWritable -Dir $FfDir)) {
        Write-Host "SKIP $FfDir (not writable)"
        return $false
    }

    $manifest = Find-SwipeManifest -FfDir $FfDir

    if ($manifest) {
        $backup = Split-Path -Parent $manifest
        Write-Host "  using manifest $manifest"
        foreach ($line in (Get-Content -LiteralPath $manifest)) {
            if ($line -match '^(added|replaced)=(.*)$') {
                $target = $Matches[2]
                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Force
                    Write-Host "  removed $target"
                }
            } elseif ($line -match '^existed=(.*)$') {
                $target = $Matches[1]
                $orig = Join-Path $backup ((Split-Path -Leaf $target) + ".orig")
                if (Test-Path -LiteralPath $orig) {
                    Write-Host "  restoring pre-existing $target"
                    Copy-Item -LiteralPath $orig -Destination $target -Force
                } else {
                    Write-Host "  WARNING: no backup for pre-existing $target; leaving it alone"
                }
            }
        }
    } else {
        # No manifest: only touch files that carry our marker, never anything else.
        Write-Host "  no manifest found; removing marked files only"
        if (Test-Path -LiteralPath $cfg) {
            $text = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
            if ($text -and ($text -match [regex]::Escape($SwipeMarker) -or $text -match "swipe-anim")) {
                Remove-Item -LiteralPath $cfg -Force
                Write-Host "  removed $cfg"
            } else {
                Write-Host "  leaving $cfg (not ours: no marker)"
            }
        }
        # local-settings.js carries no marker of its own, so match on its contents.
        if (Test-Path -LiteralPath $pref) {
            $text = Get-Content -LiteralPath $pref -Raw -ErrorAction SilentlyContinue
            if ($text -and $text -match 'general\.config\.filename' -and $text -match 'mozilla\.cfg') {
                Remove-Item -LiteralPath $pref -Force
                Write-Host "  removed $pref"
            }
        }
    }

    Write-Host "OK   $FfDir"
    return $true
}

$ok = 0
$fail = 0
foreach ($dir in $selected) {
    if (Uninstall-SwipeOne -FfDir $dir) { $ok++ } else { $fail++ }
}

Write-Host ""
Write-Host "Removed from $ok installation(s); $fail skipped."
Write-Host ""
Write-Host "Restart Firefox to return to its stock swipe behaviour."
Write-Host ""
Write-Host "The preferences the script set at runtime (widget.swipe.pixel-size,"
Write-Host "widget.swipe.velocity-twitch-tolerance, widget.swipe.success-velocity-contribution)"
Write-Host "are cleared when it unloads. To clear them by hand, reset them in about:config."
