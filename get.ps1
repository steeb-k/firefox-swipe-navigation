# Bootstrap installer, meant to be piped to PowerShell:
#
#   irm https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.ps1 | iex
#
# The Windows counterpart to get.sh. It establishes a permanent checkout and
# then hands over to install.ps1. The checkout has to be permanent, and has to
# stay: install.ps1 bakes the absolute path of swipe-anim.js into the mozilla.cfg
# loader, so a temp directory would leave Firefox pointing at a file that no
# longer exists. Keeping it under your own profile (rather than cloning
# elevated) is also what preserves the "edit the payload and restart, no admin
# needed" workflow.
#
# Environment:
#   SWIPE_HOME         where to keep the checkout
#                      (default: %LOCALAPPDATA%\firefox-swipe-navigation)
#   SWIPE_REPO         clone from somewhere else
#   SWIPE_REF          branch or tag to check out (default: main)
#   SWIPE_CLONE_ONLY   set to 1 to stop after the checkout, installing nothing
#   SWIPE_ASSUME_ALL   forwarded to install.ps1: install into every detected
#                      Firefox without prompting
#   SWIPE_EXTRA_DIRS   forwarded to install.ps1: extra locations to search
#                      (semicolon-separated)

# Everything lives in a function, for the same reason get.sh does: this text is
# executed by iex in the caller's own session, so a bare `exit` would close the
# user's shell and a stray variable would linger in it. A function gets its own
# scope and `return` stays inside it.
function Invoke-SwipeBootstrap {
    $ErrorActionPreference = "Stop"

    $repo = $env:SWIPE_REPO
    if ([string]::IsNullOrWhiteSpace($repo)) {
        $repo = "https://github.com/steeb-k/firefox-swipe-navigation.git"
    }
    $ref = $env:SWIPE_REF
    if ([string]::IsNullOrWhiteSpace($ref)) { $ref = "main" }
    $dest = $env:SWIPE_HOME
    if ([string]::IsNullOrWhiteSpace($dest)) {
        $dest = Join-Path $env:LOCALAPPDATA "firefox-swipe-navigation"
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: git is required and was not found on PATH." -ForegroundColor Red
        Write-Host "Install it with:  winget install --id Git.Git -e"
        return
    }

    if (Test-Path -LiteralPath (Join-Path $dest ".git")) {
        Write-Host "Updating existing checkout at $dest"
        # --ff-only: never invent a merge over local edits to swipe-anim.js,
        # which users are explicitly invited to make. Failing here is correct.
        & git -C $dest pull --ff-only origin $ref
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "Could not fast-forward $dest." -ForegroundColor Red
            Write-Host "You probably have local changes. Keep them and install from there:"
            Write-Host ""
            Write-Host "  powershell -ExecutionPolicy Bypass -File `"$dest\install.ps1`""
            Write-Host ""
            Write-Host "Or discard them:"
            Write-Host ""
            Write-Host "  git -C `"$dest`" fetch origin; git -C `"$dest`" reset --hard origin/$ref"
            return
        }
    } elseif (Test-Path -LiteralPath $dest) {
        Write-Host "ERROR: $dest exists but is not a git checkout." -ForegroundColor Red
        Write-Host "Move it aside, or set SWIPE_HOME to a different location."
        return
    } else {
        Write-Host "Cloning into $dest"
        $parent = Split-Path -Parent $dest
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        & git clone --branch $ref --depth 1 $repo $dest
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: clone failed." -ForegroundColor Red
            return
        }
    }

    if ($env:SWIPE_CLONE_ONLY -eq "1") {
        Write-Host ""
        Write-Host "Checkout ready at $dest (SWIPE_CLONE_ONLY set; nothing installed)."
        return
    }

    $installer = Join-Path $dest "install.ps1"
    $argList = @("-ExecutionPolicy", "Bypass", "-File", "`"$installer`"")
    if (-not [string]::IsNullOrWhiteSpace($env:SWIPE_ASSUME_ALL)) { $argList += "-All" }

    # Elevation is left to the installer, which asks for it only if the chosen
    # Firefox directory actually needs it -- a per-user install under
    # %LOCALAPPDATA% is writable as yourself and never prompts.
    . (Join-Path $dest "lib.ps1")
    Write-Host ""
    if (Test-SwipeAdmin) {
        & powershell @argList
    } else {
        Write-Host "Installing. Writing into the Firefox directory needs administrator"
        Write-Host "rights, so accept the UAC prompt; the install continues in the window"
        Write-Host "it opens."
        Write-Host ""
        & powershell @($argList + "-Elevate")
    }
}

Invoke-SwipeBootstrap
