<#
.SYNOPSIS
Install the swipe navigation animation into one or more Firefox installations.

.DESCRIPTION
The Windows counterpart to install.sh. Purely additive: it refuses to overwrite
anything it has not backed up first, and writes a manifest per installation that
uninstall.ps1 uses to reverse exactly this change.

Writing into the Firefox directory needs an elevated shell -- the local
equivalent of the sudo the Linux installer asks for. -List needs no privileges
and is the way to see what would be touched.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install.ps1 -List

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install.ps1 "C:\Program Files\Mozilla Firefox"
#>
[CmdletBinding()]
param(
    # Explicit installation directories. Given any, detection is skipped.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Path,

    # Detect and print, change nothing. Works unelevated.
    [switch] $List,

    # Take every detected installation without prompting.
    [switch] $All,

    # Extra directories to include when detecting.
    [string[]] $ExtraDirs,

    # Relaunch under UAC instead of reporting that elevation is missing.
    [switch] $Elevate
)

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here "lib.ps1")

$MinFirefoxVersion = "111"

$Payload = Join-Path $Here "swipe-anim.js"
$Template = Join-Path $Here "autoconfig\mozilla.cfg.in"
$PrefsSrc = Join-Path $Here "autoconfig\local-settings.js"
$BackupRoot = $env:SWIPE_BACKUP_ROOT
if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $Here "backups" }

foreach ($f in @($Payload, $Template, $PrefsSrc)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "missing $f"
        exit 1
    }
}

if ($List) {
    $records = @(Get-SwipeInstall -ExtraDirs $ExtraDirs)
    if ($records.Count -eq 0) {
        Write-Host "No Firefox installations found."
        exit 1
    }
    Write-Host ""
    Write-Host "Detected Firefox installations:"
    Write-Host ""
    foreach ($r in $records) {
        $note = ""
        if ($r.Installed) { $note += "  [already installed]" }
        if (-not $r.Writable) { $note += "  [needs admin]" }
        if (-not $r.HasPrefs) { $note += "  [no defaults\pref]" }
        if (-not (Test-SwipeVersionGe $r.Version $MinFirefoxVersion)) {
            $note += "  [UNSUPPORTED: needs $MinFirefoxVersion+]"
        }
        Write-Host ("  {0,-52} {1} {2}{3}" -f $r.Path, $r.Name, $r.Version, $note)
    }
    Write-Host ""
    exit 0
}

# Explicit paths win over detection.
if ($Path -and $Path.Count -gt 0) {
    $selected = $Path
} else {
    $records = @(Get-SwipeInstall -ExtraDirs $ExtraDirs)
    $selected = @(Select-SwipeInstall -Mode "install" -MinVersion $MinFirefoxVersion -Records $records -AssumeAll:$All)
    if (-not $selected -or $selected.Count -eq 0) { exit 1 }
}

# Elevation is a means, not the requirement: what matters is whether the chosen
# directories can be written. A per-user install under %LOCALAPPDATA% is
# writable as yourself and needs no UAC at all, which is why this asks about the
# targets rather than about the token. Paths that do not exist are left for
# Install-SwipeOne to report properly.
$needsElevation = @($selected | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Container) -and
        (-not (Test-SwipeWritable -Dir $_) -or -not (Test-SwipeWritable -Dir (Join-Path $_ "defaults\pref")))
    })
if ($needsElevation.Count -gt 0 -and -not (Test-SwipeAdmin)) {
    if ($Elevate) {
        # -NoExit so the result stays readable after the elevated window is done;
        # a UAC window that closes on completion reports nothing.
        $argList = @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$($MyInvocation.MyCommand.Path)`"")
        if ($All) { $argList += "-All" }
        foreach ($p in $Path) { $argList += "`"$p`"" }
        Write-Host "Relaunching elevated; accept the UAC prompt."
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
    Write-Host "Or re-run this with -Elevate to be prompted by UAC, or with -List to"
    Write-Host "see what would be touched without changing anything."
    Write-Host ""
    exit 1
}

function Install-SwipeOne {
    param([string] $FfDir)

    if (-not (Test-Path -LiteralPath $FfDir -PathType Container)) {
        Write-Host "SKIP $FfDir (not a directory)"
        return $false
    }
    if (-not (Test-Path -LiteralPath (Join-Path $FfDir "application.ini"))) {
        Write-Host "SKIP $FfDir (no application.ini; not a Firefox installation)"
        return $false
    }
    $prefDir = Join-Path $FfDir "defaults\pref"
    if (-not (Test-Path -LiteralPath $prefDir -PathType Container)) {
        Write-Host "SKIP $FfDir (no defaults\pref)"
        return $false
    }

    $ver = Get-SwipeIniValue -File (Join-Path $FfDir "application.ini") -Key "Version"
    if (-not (Test-SwipeVersionGe $ver $MinFirefoxVersion)) {
        Write-Host "SKIP $FfDir (Firefox $ver; needs $MinFirefoxVersion+)"
        return $false
    }
    if (-not (Test-SwipeWritable -Dir $FfDir) -or -not (Test-SwipeWritable -Dir $prefDir)) {
        Write-Host "SKIP $FfDir (not writable even elevated; is Firefox installed read-only?)"
        return $false
    }

    $tail = ($FfDir -replace '[^A-Za-z0-9]', '_')
    if ($tail.Length -gt 40) { $tail = $tail.Substring($tail.Length - 40) }
    $stamp = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $tail
    $backup = Join-Path $BackupRoot $stamp
    $manifest = Join-Path $backup "manifest.txt"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null

    $lines = @(
        "# swipe navigation install manifest",
        "# created: $stamp",
        "ff_dir=$FfDir",
        "payload=$Payload",
        "firefox_version=$ver"
    )

    $targetCfg = Join-Path $FfDir "mozilla.cfg"
    $targetPref = Join-Path $prefDir "local-settings.js"
    foreach ($target in @($targetCfg, $targetPref)) {
        if (Test-Path -LiteralPath $target) {
            $text = Get-Content -LiteralPath $target -Raw -ErrorAction SilentlyContinue
            if ($text -and $text -match [regex]::Escape($SwipeMarker)) {
                # One of ours from a previous run; replacing it is not destructive.
                $lines += "replaced=$target"
            } else {
                Write-Host "  backing up pre-existing $target"
                Copy-Item -LiteralPath $target -Destination (Join-Path $backup ((Split-Path -Leaf $target) + ".orig")) -Force
                $lines += "existed=$target"
            }
        } else {
            $lines += "added=$target"
        }
    }
    Write-SwipeTextFile -Path $manifest -Text (($lines -join "`r`n") + "`r`n")

    # Bake the payload's location into the loader as a file: URL. Uri does the
    # drive-letter and escaping work that a string substitution would get wrong
    # the first time the checkout lives under a path with a space in it.
    $payloadUrl = ([System.Uri]$Payload).AbsoluteUri
    $cfgText = (Get-Content -LiteralPath $Template -Raw) -replace '@PAYLOAD_URL@', $payloadUrl
    Write-SwipeTextFile -Path (Join-Path $backup "mozilla.cfg.generated") -Text $cfgText
    Write-SwipeTextFile -Path $targetCfg -Text $cfgText
    Write-SwipeTextFile -Path $targetPref -Text (Get-Content -LiteralPath $PrefsSrc -Raw)

    Write-SwipeTextFile -Path (Join-Path $BackupRoot "latest.txt") -Text ($backup + "`r`n")
    Write-Host "OK   $FfDir  (Firefox $ver)"
    return $true
}

$ok = 0
$fail = 0
foreach ($dir in $selected) {
    if (Install-SwipeOne -FfDir $dir) { $ok++ } else { $fail++ }
}

Write-Host ""
Write-Host "Installed into $ok installation(s); $fail skipped."
if ($ok -gt 0) {
    Write-Host ""
    Write-Host "Payload (edit freely, no admin needed, just restart Firefox):"
    Write-Host "  $Payload"
    Write-Host ""
    Write-Host "Manifests: $BackupRoot"
    Write-Host "Roll back with: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $Here 'uninstall.ps1')`""
    Write-Host ""
    Write-Host "Quit Firefox completely, then start it again and swipe horizontally"
    Write-Host "with two fingers."
    Write-Host ""
    Write-Host "NOTE: the installed files are not owned by the Firefox updater, so they"
    Write-Host "      survive an upgrade and could misbehave on a future version."
    Write-Host "      Uninstall before a major update, or re-check afterwards."
    exit 0
}
exit 1
