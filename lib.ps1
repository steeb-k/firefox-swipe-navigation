# Shared helpers for install.ps1 / uninstall.ps1: finding Firefox installations
# on Windows and letting the user choose among them. The counterpart to lib.sh,
# which does the same job on Linux.
#
# The two halves deliberately write the same manifest format, so a manifest is
# readable by either uninstaller. Nothing else is shared: detection, the
# writability test and the privilege check have no common ground between a
# package-managed /usr/lib and an installer-managed Program Files.
#
# Dot-source this; every function and $SwipeMarker land in the caller's scope.

$SwipeMarker = "firefox-swipe-navigation-marker"

# Firefox writes its install location to the registry, which beats guessing at
# paths: it covers a per-user install, a D: drive, and the channels that do not
# live in a directory called "Mozilla Firefox". The filesystem sweep below is
# the backstop for an install that never registered itself -- an extracted
# archive, a portable copy, a build tree.
function Get-SwipeRegistryDir {
    $roots = @(
        "HKLM:\SOFTWARE\Mozilla",
        "HKLM:\SOFTWARE\WOW6432Node\Mozilla",
        "HKCU:\SOFTWARE\Mozilla"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        # Products are "Mozilla Firefox", "Firefox Developer Edition", "Nightly",
        # each holding one subkey per installed version.
        foreach ($product in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            foreach ($ver in (Get-ChildItem $product.PSPath -ErrorAction SilentlyContinue)) {
                $main = Join-Path $ver.PSPath "Main"
                if (-not (Test-Path $main)) { continue }
                $props = Get-ItemProperty $main -ErrorAction SilentlyContinue
                if ($null -eq $props) { continue }
                $dir = $props.PSObject.Properties['Install Directory']
                if ($null -ne $dir -and -not [string]::IsNullOrWhiteSpace($dir.Value)) {
                    $dir.Value
                }
            }
        }
    }
}

function Get-SwipeCandidateDir {
    param([string[]] $ExtraDirs)

    Get-SwipeRegistryDir

    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432,
        (Join-Path $env:LOCALAPPDATA ""),
        "C:\"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $names = @(
        "Mozilla Firefox",
        "Firefox Developer Edition",
        "Firefox Nightly",
        "Firefox ESR",
        "Firefox"
    )
    foreach ($root in $roots) {
        foreach ($name in $names) {
            Join-Path $root $name
        }
    }

    # Semicolons, because that is what PATH uses here and a Windows path can
    # contain almost anything else.
    if (-not [string]::IsNullOrWhiteSpace($env:SWIPE_EXTRA_DIRS)) {
        $env:SWIPE_EXTRA_DIRS -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    if ($ExtraDirs) {
        $ExtraDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
}

# Writability cannot be read off an ACL with any confidence here -- inherited
# denies, virtualisation and the admin token all conspire -- so the honest test
# is to write a file and see what happens.
function Test-SwipeWritable {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    $probe = Join-Path $Dir (".swipe-write-probe-" + [System.Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($probe, "")
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Get-SwipeIniValue {
    param([string] $File, [string] $Key)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $File -ErrorAction SilentlyContinue)) {
        if ($line -match "^$Key=(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

# One record per detected installation: Path, Version, Name, Installed, Writable.
function Get-SwipeInstall {
    param([string[]] $ExtraDirs)

    $seen = @{}
    foreach ($dir in (Get-SwipeCandidateDir -ExtraDirs $ExtraDirs)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        $full = $null
        try { $full = (Get-Item -LiteralPath $dir -ErrorAction Stop).FullName } catch { continue }
        $key = $full.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }

        $ini = Join-Path $full "application.ini"
        if (-not (Test-Path -LiteralPath $ini)) { continue }
        $seen[$key] = $true

        $version = Get-SwipeIniValue -File $ini -Key "Version"
        $name = Get-SwipeIniValue -File $ini -Key "Name"
        if ([string]::IsNullOrWhiteSpace($version)) { $version = "?" }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Firefox" }

        # Match the marker, but also plain "swipe-anim", so an install made
        # before the marker existed is still recognised.
        $installed = $false
        $cfg = Join-Path $full "mozilla.cfg"
        if (Test-Path -LiteralPath $cfg) {
            $text = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
            if ($text -and ($text -match [regex]::Escape($SwipeMarker) -or $text -match "swipe-anim")) {
                $installed = $true
            }
        }

        $prefDir = Join-Path $full "defaults\pref"
        $writable = (Test-SwipeWritable -Dir $full) -and (Test-SwipeWritable -Dir $prefDir)

        [PSCustomObject]@{
            Path      = $full
            Version   = $version
            Name      = $name
            Installed = $installed
            Writable  = $writable
            HasPrefs  = (Test-Path -LiteralPath $prefDir -PathType Container)
        }
    }
}

# True if $Have >= $Min. A Firefox version can carry a suffix ("152.0a1"), so
# only the leading dotted-numeric part is compared, and an unreadable version is
# given the benefit of the doubt exactly as lib.sh does.
function Test-SwipeVersionGe {
    param([string] $Have, [string] $Min)
    if ([string]::IsNullOrWhiteSpace($Have) -or $Have -eq "?") { return $true }
    if ($Have -notmatch '^([0-9]+(\.[0-9]+)*)') { return $true }
    $a = $Matches[1]
    if ($Min -notmatch '^([0-9]+(\.[0-9]+)*)') { return $true }
    $b = $Matches[1]
    try {
        return ([version]$a -ge [version]$b)
    } catch {
        # Single-component versions ("152") do not parse as [version].
        return ([int]($a -split '\.')[0] -ge [int]($b -split '\.')[0])
    }
}

function Test-SwipeAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Prints the detected installations and reads a selection. $Mode is "install" or
# "uninstall" and changes both the wording and which rows are offered. Returns
# the chosen paths, or nothing if the user declined.
function Select-SwipeInstall {
    param(
        [string] $Mode,
        [string] $MinVersion,
        [object[]] $Records,
        [switch] $AssumeAll
    )

    if (-not $Records -or $Records.Count -eq 0) {
        Write-Error "No Firefox installations found. Pass one explicitly, or set SWIPE_EXTRA_DIRS."
        return
    }

    $offered = @($Records | Where-Object { $Mode -ne "uninstall" -or $_.Installed })
    if ($offered.Count -eq 0) {
        Write-Error "Found $($Records.Count) Firefox installation(s), but none have swipe navigation installed."
        return
    }

    Write-Host ""
    Write-Host "Detected Firefox installations:"
    Write-Host ""
    for ($i = 0; $i -lt $offered.Count; $i++) {
        $r = $offered[$i]
        $note = ""
        if ($r.Installed) { $note += "  [already installed]" }
        if (-not $r.Writable) { $note += "  [needs admin]" }
        if ($Mode -eq "install" -and $MinVersion -and -not (Test-SwipeVersionGe $r.Version $MinVersion)) {
            $note += "  [UNSUPPORTED: needs $MinVersion+]"
        }
        Write-Host ("  {0}) {1,-52} {2} {3}{4}" -f ($i + 1), $r.Path, $r.Name, $r.Version, $note)
    }
    Write-Host ""

    $prompt = "Select installation(s) to $Mode [e.g. 1  or  1,3  or  all]"
    if ($AssumeAll -or -not [string]::IsNullOrWhiteSpace($env:SWIPE_ASSUME_ALL)) {
        $reply = "all"
        Write-Host "${prompt}: all  (assuming all)"
    } else {
        $reply = Read-Host $prompt
    }

    $reply = ($reply -replace '\s', '')
    if ([string]::IsNullOrWhiteSpace($reply) -or $reply -eq "q") {
        Write-Error "Nothing selected."
        return
    }

    if ($reply -eq "all" -or $reply -eq "a") {
        return $offered | ForEach-Object { $_.Path }
    }

    $picks = @()
    foreach ($tok in ($reply -split ',')) {
        if ($tok -notmatch '^[0-9]+$') {
            Write-Error "Invalid selection: $tok"
            return
        }
        $n = [int]$tok
        if ($n -lt 1 -or $n -gt $offered.Count) {
            Write-Error "Invalid selection: $tok"
            return
        }
        $picks += $offered[$n - 1].Path
    }
    return $picks
}

# Firefox reads mozilla.cfg and local-settings.js as plain bytes; a UTF-8 BOM in
# the pref file is not something to find out about the hard way.
function Write-SwipeTextFile {
    param([string] $Path, [string] $Text)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}
