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
# NOTHING HERE LOADS ANOTHER .ps1 FROM DISK. This text arrives through iex,
# which execution policy permits because it is a string rather than a file --
# but dot-sourcing or running a script file is exactly what a machine at the
# default Restricted policy refuses, and that is the state a fresh Windows
# install is in. So the one helper needed here is defined inline, and the
# installer is launched through `powershell -ExecutionPolicy Bypass -File`,
# which carries its own permission with it.
#
# git is optional. With git the checkout is a clone, which is what makes
# re-running this an update and what lets you keep local edits. Without it the
# source is downloaded as a zip, and the update path becomes a re-download that
# refuses to overwrite anything you have changed.
#
# Environment:
#   SWIPE_HOME         where to keep the checkout
#                      (default: %LOCALAPPDATA%\firefox-swipe-navigation)
#   SWIPE_REPO         clone from somewhere else
#   SWIPE_REF          branch or tag to check out (default: main)
#   SWIPE_NO_GIT       set to 1 to download a zip even if git is installed
#   SWIPE_ZIP_URL      download the zip from somewhere else
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
    # Invoke-WebRequest spends most of its time drawing the progress bar in
    # Windows PowerShell. Function-scoped, so the caller's session is untouched.
    $ProgressPreference = "SilentlyContinue"

    # Nested rather than top level: iex runs this in the caller's own session,
    # and one lingering name is enough.
    function Test-SwipeAdminInline {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Invoke-SwipeGitCheckout {
        param([string] $Repo, [string] $Ref, [string] $Dest)

        if (Test-Path -LiteralPath (Join-Path $Dest ".git")) {
            Write-Host "Updating existing checkout at $Dest"
            # --ff-only: never invent a merge over local edits to swipe-anim.js,
            # which users are explicitly invited to make. Failing here is correct.
            & git -C $Dest pull --ff-only origin $Ref
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host "Could not fast-forward $Dest." -ForegroundColor Red
                Write-Host "You probably have local changes. Keep them and install from there:"
                Write-Host ""
                Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Dest\install.ps1`""
                Write-Host ""
                Write-Host "Or discard them:"
                Write-Host ""
                Write-Host "  git -C `"$Dest`" fetch origin; git -C `"$Dest`" reset --hard origin/$Ref"
                return $false
            }
            return $true
        }

        Write-Host "Cloning into $Dest"
        $parent = Split-Path -Parent $Dest
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        & git clone --branch $Ref --depth 1 $Repo $Dest
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: clone failed." -ForegroundColor Red
            return $false
        }
        return $true
    }

    # The no-git path. GitHub serves any branch as a zip, so the source is one
    # download and an Expand-Archive away; what is lost is git's ability to tell
    # your edits from upstream's, which is why refreshing an existing directory
    # compares file by file and stops rather than guess.
    function Invoke-SwipeZipCheckout {
        param([string] $Repo, [string] $Ref, [string] $Dest)

        $zipUrl = $env:SWIPE_ZIP_URL
        if ([string]::IsNullOrWhiteSpace($zipUrl)) {
            if ($Repo -match '^https://github\.com/([^/]+)/([^/]+?)(\.git)?$') {
                $zipUrl = "https://github.com/$($Matches[1])/$($Matches[2])/archive/refs/heads/$Ref.zip"
            } else {
                Write-Host "ERROR: git is not installed, and no zip URL could be derived from" -ForegroundColor Red
                Write-Host "  $Repo"
                Write-Host "Install git (winget install --id Git.Git -e), or set SWIPE_ZIP_URL."
                return $false
            }
        }

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("swipe-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $zip = Join-Path $tmp "source.zip"
            Write-Host "Downloading $zipUrl"
            try {
                # Older Windows PowerShell defaults below TLS 1.2, which GitHub
                # refuses outright.
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            } catch { }
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

            # GitHub wraps the tree in one directory named <repo>-<ref>.
            $top = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
            if (-not $top) {
                Write-Host "ERROR: the downloaded archive was empty." -ForegroundColor Red
                return $false
            }

            if (-not (Test-Path -LiteralPath $Dest)) {
                Write-Host "Unpacking into $Dest"
                $parent = Split-Path -Parent $Dest
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Move-Item -LiteralPath $top.FullName -Destination $Dest
            } else {
                # Refreshing in place. Without git there is no history to compare
                # against, so the only safe rule is: if a file here differs from
                # the one being installed, it is either your edit or a version
                # you did not ask to lose, and this stops.
                Write-Host "Refreshing $Dest"
                $changed = @()
                foreach ($src in (Get-ChildItem -LiteralPath $top.FullName -Recurse -File)) {
                    $rel = $src.FullName.Substring($top.FullName.Length).TrimStart('\')
                    $mine = Join-Path $Dest $rel
                    if (Test-Path -LiteralPath $mine) {
                        $a = (Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash
                        $b = (Get-FileHash -LiteralPath $mine -Algorithm SHA256).Hash
                        if ($a -ne $b) { $changed += $rel }
                    }
                }
                if ($changed.Count -gt 0) {
                    Write-Host ""
                    Write-Host "$Dest differs from the version being downloaded:" -ForegroundColor Red
                    foreach ($c in $changed) { Write-Host "  $c" }
                    Write-Host ""
                    Write-Host "Those are either your own edits or an older release. Nothing has been"
                    Write-Host "overwritten. Keep them and install what you have:"
                    Write-Host ""
                    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Dest\install.ps1`""
                    Write-Host ""
                    Write-Host "Or delete $Dest and run this again for a clean copy."
                    Write-Host "(Installing git first would make this an ordinary update instead.)"
                    return $false
                }
                Copy-Item -Path (Join-Path $top.FullName "*") -Destination $Dest -Recurse -Force
            }

            # A zip fetched over the internet marks what comes out of it, and a
            # marked script is refused under any policy short of Bypass. The
            # installer is launched with Bypass anyway; clearing the mark is what
            # makes the checkout pleasant to use by hand afterwards.
            Get-ChildItem -LiteralPath $Dest -Filter *.ps1 -Recurse -File |
                ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
            return $true
        } catch {
            Write-Host "ERROR: could not download or unpack the source: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

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

    $haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if ($env:SWIPE_NO_GIT -eq "1") { $haveGit = $false }
    $isClone = Test-Path -LiteralPath (Join-Path $dest ".git")

    if ($haveGit -and ($isClone -or -not (Test-Path -LiteralPath $dest))) {
        if (-not (Invoke-SwipeGitCheckout -Repo $repo -Ref $ref -Dest $dest)) { return }
    } else {
        if ($isClone -and -not $haveGit) {
            Write-Host "$dest is a git checkout but git is not installed; using it as it stands."
            Write-Host "Install git to be able to update it."
        } elseif (-not (Invoke-SwipeZipCheckout -Repo $repo -Ref $ref -Dest $dest)) {
            return
        }
    }

    if ($env:SWIPE_CLONE_ONLY -eq "1") {
        Write-Host ""
        Write-Host "Checkout ready at $dest (SWIPE_CLONE_ONLY set; nothing installed)."
        return
    }

    $installer = Join-Path $dest "install.ps1"
    if (-not (Test-Path -LiteralPath $installer)) {
        Write-Host "ERROR: $installer is missing; the checkout looks incomplete." -ForegroundColor Red
        return
    }

    # -ExecutionPolicy Bypass is not optional here: a default Windows install is
    # at Restricted, and these files may additionally carry the mark of the web
    # if they arrived as a zip. Bypass covers both for this one invocation
    # without changing any policy on the machine.
    $argList = @("-ExecutionPolicy", "Bypass", "-File", "`"$installer`"")
    if (-not [string]::IsNullOrWhiteSpace($env:SWIPE_ASSUME_ALL)) { $argList += "-All" }

    # Elevation is left to the installer, which asks for it only if the chosen
    # Firefox directory actually needs it -- a per-user install under
    # %LOCALAPPDATA% is writable as yourself and never prompts.
    Write-Host ""
    if (Test-SwipeAdminInline) {
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
