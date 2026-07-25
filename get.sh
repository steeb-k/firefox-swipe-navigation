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
#   SWIPE_ASSUME_ALL   forwarded to install.sh: install into every detected
#                      Firefox without prompting
#   SWIPE_EXTRA_DIRS   forwarded to install.sh: extra locations to search
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

  local missing=()
  local cmd
  for cmd in git sudo; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    echo "ERROR: missing required command(s): ${missing[*]}" >&2
    return 1
  fi

  if [[ -d "$dest/.git" ]]; then
    echo "Updating existing checkout at $dest"
    # --ff-only: never invent a merge over local edits to swipe-anim.js, which
    # users are explicitly invited to make. Failing here is the correct outcome.
    if ! git -C "$dest" pull --ff-only origin "$ref"; then
      cat >&2 <<EOF

Could not fast-forward $dest.
You probably have local changes. Keep them and install from there:

  cd "$dest" && sudo ./install.sh

Or discard them:

  git -C "$dest" fetch origin && git -C "$dest" reset --hard "origin/$ref"
EOF
      return 1
    fi
  elif [[ -e "$dest" ]]; then
    echo "ERROR: $dest exists but is not a git checkout." >&2
    echo "Move it aside, or set SWIPE_HOME to a different location." >&2
    return 1
  else
    echo "Cloning into $dest"
    mkdir -p "$(dirname "$dest")"
    git clone --branch "$ref" --depth 1 "$repo" "$dest"
  fi

  echo
  echo "Installing. sudo is needed to write into the Firefox directory."
  echo

  # Forward our own settings by hand: sudo scrubs the environment, and -E would
  # pass through everything rather than just these.
  local -a env_args=()
  [[ -n "${SWIPE_ASSUME_ALL:-}" ]] && env_args+=("SWIPE_ASSUME_ALL=$SWIPE_ASSUME_ALL")
  [[ -n "${SWIPE_EXTRA_DIRS:-}" ]] && env_args+=("SWIPE_EXTRA_DIRS=$SWIPE_EXTRA_DIRS")

  # </dev/null so install.sh cannot read leftovers of this script from the pipe.
  # Its own prompt reads /dev/tty directly, so it still works interactively.
  # ${a[@]+"${a[@]}"} rather than "${a[@]}": expanding an empty array under
  # `set -u` is an error before bash 4.4.
  sudo env ${env_args[@]+"${env_args[@]}"} "$dest/install.sh" </dev/null
}

main "$@"
