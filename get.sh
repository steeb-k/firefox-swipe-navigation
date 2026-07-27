#!/usr/bin/env bash
# Bootstrap installer, meant to be piped to a shell:
#
#   curl -fsSL https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.sh | bash
#
# It establishes a permanent checkout and then hands over to install.sh. The
# checkout has to be permanent, and has to stay: install.sh bakes its absolute
# path to swipe-anim.js into the mozilla.cfg loader, so a temp directory would
# leave Firefox pointing at a file that no longer exists. Keeping it in the
# user's home (rather than cloning as root) is also what preserves the "edit the
# payload and restart, no root needed" workflow.
#
# Environment:
#   SWIPE_HOME         where to keep the checkout
#                      (default: ~/.local/share/firefox-swipe-navigation)
#   SWIPE_REPO         clone from somewhere else
#   SWIPE_REF          branch or tag to check out (default: main)
#   SWIPE_NO_GIT       set to 1 to download a tarball even if git is installed
#   SWIPE_TARBALL_URL  download the tarball from somewhere else
#   SWIPE_ASSUME_ALL   forwarded to install.sh: install into every detected
#                      Firefox without prompting
#   SWIPE_EXTRA_DIRS   forwarded to install.sh: extra locations to search
#
# git is optional. With git the checkout is a clone, which is what makes
# re-running this an update and what lets you keep local edits. Without it the
# source is downloaded as a tarball and the update path becomes a re-download
# that refuses to overwrite anything you have changed. This matters on macOS in
# particular, where /usr/bin/git is a Command Line Tools shim that exists even
# when git does not.
set -euo pipefail

# Everything lives in a function so that bash parses the whole script before
# running any of it. Piped to a shell, the script is read incrementally from the
# pipe; without this, a command that consumed stdin could truncate the rest.
main() {
  local repo="${SWIPE_REPO:-https://github.com/steeb-k/firefox-swipe-navigation.git}"
  local ref="${SWIPE_REF:-main}"
  local dest="${SWIPE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/firefox-swipe-navigation}"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    cat >&2 <<'EOF'
ERROR: run this without sudo.

The checkout must belong to you, not to root: swipe-anim.js stays there and is
re-read every time a Firefox window opens, so you want to be able to edit it
without root. This script will call sudo itself, for the one step that needs it.

  curl -fsSL https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.sh | bash
EOF
    return 1
  fi

  local os
  os="$(uname -s)"

  # git being on PATH is not the same as git working. On macOS /usr/bin/git is a
  # Command Line Tools shim that exists on a machine which has never installed
  # them, and running it opens a GUI installer instead of doing anything -- so
  # ask it to do something and see.
  have_git() {
    [[ "${SWIPE_NO_GIT:-}" == 1 ]] && return 1
    command -v git >/dev/null 2>&1 || return 1
    git --version >/dev/null 2>&1
  }

  # sudo is a Linux requirement only. On macOS the Firefox bundle belongs to the
  # user who installed it, and where it does not, the obstacle is App Management
  # rather than ownership -- which sudo cannot grant either. See install.sh.
  if [[ "$os" != Darwin ]] && ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: missing required command: sudo" >&2
    return 1
  fi

  # The no-git path, mirroring get.ps1: GitHub serves any branch as a tarball.
  # What is lost is git's ability to tell your edits from upstream's, which is
  # why refreshing an existing directory compares file by file and stops rather
  # than guess.
  tarball_checkout() {
    local url="${SWIPE_TARBALL_URL:-}"
    if [[ -z "$url" ]]; then
      local slug="${repo%.git}"
      case "$slug" in
        https://github.com/*)
          url="${slug}/archive/refs/heads/${ref}.tar.gz"
          ;;
        *)
          echo "ERROR: git is unavailable and no tarball URL could be derived from" >&2
          echo "  $repo" >&2
          echo "Install git, or set SWIPE_TARBALL_URL." >&2
          return 1
          ;;
      esac
    fi

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/swipe-XXXXXX") || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    echo "Downloading $url"
    curl -fsSL "$url" -o "$tmp/source.tar.gz" || {
      echo "ERROR: download failed." >&2
      return 1
    }
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/source.tar.gz" -C "$tmp/x" || {
      echo "ERROR: could not unpack the archive." >&2
      return 1
    }

    # GitHub wraps the tree in one directory named <repo>-<ref>.
    local top
    top=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -z "$top" ]]; then
      echo "ERROR: the downloaded archive was empty." >&2
      return 1
    fi

    if [[ ! -e "$dest" ]]; then
      echo "Unpacking into $dest"
      mkdir -p "$(dirname "$dest")"
      mv "$top" "$dest"
      return 0
    fi

    # Refreshing in place, with no history to consult: if a file here differs
    # from the one being installed, it is either your edit or a version you did
    # not ask to lose, and this stops.
    echo "Refreshing $dest"
    local changed=() src rel
    while IFS= read -r src; do
      rel="${src#"$top"/}"
      if [[ -f "$dest/$rel" ]] && ! cmp -s "$src" "$dest/$rel"; then
        changed+=("$rel")
      fi
    done < <(find "$top" -type f)

    if ((${#changed[@]} > 0)); then
      echo >&2
      echo "$dest differs from the version being downloaded:" >&2
      printf '  %s\n' "${changed[@]}" >&2
      cat >&2 <<EOF

Those are either your own edits or an older release. Nothing has been
overwritten. Keep them and install what you have:

  cd "$dest" && ./install.sh

Or delete $dest and run this again for a clean copy.
(Installing git first would make this an ordinary update instead.)
EOF
      return 1
    fi

    cp -R "$top/." "$dest/"
    return 0
  }

  if [[ -d "$dest/.git" ]]; then
    if ! have_git; then
      echo "$dest is a git checkout but git is unavailable; using it as it stands."
      echo "Install git to be able to update it."
    else
      echo "Updating existing checkout at $dest"
      # --ff-only: never invent a merge over local edits to swipe-anim.js, which
      # users are explicitly invited to make. Failing here is the correct outcome.
      if ! git -C "$dest" pull --ff-only origin "$ref"; then
        cat >&2 <<EOF

Could not fast-forward $dest.
You probably have local changes. Keep them and install from there:

  cd "$dest" && ./install.sh

Or discard them:

  git -C "$dest" fetch origin && git -C "$dest" reset --hard "origin/$ref"
EOF
        return 1
      fi
    fi
  elif have_git && [[ ! -e "$dest" ]]; then
    echo "Cloning into $dest"
    mkdir -p "$(dirname "$dest")"
    git clone --branch "$ref" --depth 1 "$repo" "$dest"
  else
    tarball_checkout || return 1
  fi

  [[ -x "$dest/install.sh" ]] || chmod +x "$dest/install.sh" 2>/dev/null || true

  echo

  # </dev/null so install.sh cannot read leftovers of this script from the pipe.
  # Its own prompt reads /dev/tty directly, so it still works interactively.
  if [[ "$os" == Darwin ]]; then
    # Deliberately not sudo. /Applications/Firefox.app belongs to the user who
    # installed it, so there is nothing to escalate for -- and root would leave
    # root-owned files inside a user-owned bundle, which makes Firefox's own
    # updater fail. install.sh explains whichever obstacle it actually meets.
    echo "Installing."
    echo
    "$dest/install.sh" </dev/null
  else
    echo "Installing. sudo is needed to write into the Firefox directory."
    echo

    # Forward our own settings by hand: sudo scrubs the environment, and -E would
    # pass through everything rather than just these.
    # ${a[@]+"${a[@]}"} rather than "${a[@]}": expanding an empty array under
    # `set -u` is an error before bash 4.4.
    local -a env_args=()
    [[ -n "${SWIPE_ASSUME_ALL:-}" ]] && env_args+=("SWIPE_ASSUME_ALL=$SWIPE_ASSUME_ALL")
    [[ -n "${SWIPE_EXTRA_DIRS:-}" ]] && env_args+=("SWIPE_EXTRA_DIRS=$SWIPE_EXTRA_DIRS")

    sudo env ${env_args[@]+"${env_args[@]}"} "$dest/install.sh" </dev/null
  fi
}

main "$@"
