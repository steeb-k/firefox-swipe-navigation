# Shared helpers for install.sh / uninstall.sh: finding Firefox installations
# and letting the user choose among them. Covers Linux and macOS; lib.ps1 is the
# Windows counterpart, separate only because PowerShell is.
# shellcheck shell=bash

MARKER="firefox-swipe-navigation-marker"

SWIPE_OS="$(uname -s)"

# On macOS a Firefox "installation directory" is Firefox.app/Contents/Resources:
# the GRE directory, which is where application.ini lives, where autoconfig
# resolves general.config.filename, and where defaults/pref hangs off. Every path
# this library hands around is that inner directory, so the rest of the code
# stays platform-neutral -- but a user types, and reads, the bundle.
swipe_normalize_dir() {
  local d="${1%/}"
  case "$d" in
    *.app) printf '%s\n' "$d/Contents/Resources" ;;
    *) printf '%s\n' "$d" ;;
  esac
}

# The inverse, for display and for the checks that are properties of the bundle
# rather than of the directory inside it.
swipe_bundle_of() {
  case "$1" in
    */Contents/Resources) printf '%s\n' "${1%/Contents/Resources}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Places a Firefox installation directory commonly lives. Globs are fine; each
# candidate is validated by the presence of application.ini, and duplicates are
# collapsed by real path (many distros symlink /usr/lib64 -> /usr/lib).
swipe_candidate_dirs() {
  local homedir="${HOME:-/root}"
  # When running under sudo, also look in the invoking user's home.
  if [[ -n "${SUDO_USER:-}" ]]; then
    local sudo_home
    if [[ "$SWIPE_OS" == Darwin ]]; then
      sudo_home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //' || true)
    else
      sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
    fi
    [[ -n "$sudo_home" ]] && homedir="$sudo_home"
  fi

  if [[ "$SWIPE_OS" == Darwin ]]; then
    swipe_candidate_dirs_macos "$homedir"
    return
  fi

  printf '%s\n' \
    /usr/lib/firefox \
    /usr/lib/firefox-* \
    /usr/lib64/firefox \
    /usr/lib64/firefox-* \
    /usr/local/lib/firefox \
    /usr/local/lib/firefox-* \
    /opt/firefox \
    /opt/firefox-* \
    /snap/firefox/current/usr/lib/firefox \
    /var/lib/flatpak/app/org.mozilla.firefox/current/active/files/lib/firefox \
    "$homedir/.local/share/flatpak/app/org.mozilla.firefox/current/active/files/lib/firefox" \
    "$homedir/.local/share/firefox" \
    "$homedir/firefox" \
    "$homedir/opt/firefox" \
    ${SWIPE_EXTRA_DIRS:-} \
    2>/dev/null
}

# Spotlight is macOS's answer to the registry lookup lib.ps1 does on Windows: it
# knows where the bundles actually are, including a Firefox somewhere unusual and
# the channels that are not called "Firefox.app". The globs stay as the backstop,
# because an unindexed volume tells mdfind nothing.
#
# The query matches Thunderbird too; the browser/ subdirectory required in
# swipe_detect_installs is what sorts that out.
swipe_candidate_dirs_macos() {
  local homedir="$1" line
  while IFS= read -r line; do
    [[ -n "$line" ]] && swipe_normalize_dir "$line"
  done < <(mdfind "kMDItemCFBundleIdentifier == 'org.mozilla.*'" 2>/dev/null)

  local d
  for d in \
    /Applications/Firefox*.app \
    "$homedir/Applications/Firefox"*.app \
    ${SWIPE_EXTRA_DIRS:-}; do
    if [[ -e "$d" ]]; then
      swipe_normalize_dir "$d"
    fi
  done
  # An unmatched glob on the last candidate would otherwise make this function's
  # status the failed test, which under `set -e` takes the caller with it.
  return 0
}

# Whether a directory can actually be written to, which on macOS the permission
# bits do not answer. App Management (TCC) refuses writes inside another team's
# signed bundle while the mode bits still say yes, and sudo does not change that
# -- TCC attributes to the responsible GUI application, not to the euid. So the
# honest test is to write a file and see what happens, exactly as
# Test-SwipeWritable in lib.ps1 does for Windows ACLs.
swipe_probe_writable() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local probe="$dir/.swipe-write-probe-$$"
  if : > "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null
    return 0
  fi
  return 1
}

# The nearest ancestor that exists. defaults/pref does not ship on macOS, so the
# question "can the installer write there" is really about the deepest directory
# that is already present.
swipe_nearest_existing() {
  local d="${1%/}"
  while [[ -n "$d" && "$d" != / && ! -d "$d" ]]; do
    d="${d%/*}"
  done
  printf '%s\n' "${d:-/}"
}

# Emits one TAB-separated record per detected installation:
#   path <TAB> version <TAB> name <TAB> installed(yes|no) <TAB> writable(yes|no)
swipe_detect_installs() {
  local seen=() dir real ver name installed writable
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ -d "$dir" ]] || continue
    [[ -f "$dir/application.ini" ]] || continue
    # Thunderbird ships an application.ini too, and answers the same Spotlight
    # query. Only a browser has browser/.
    if [[ "$SWIPE_OS" == Darwin && ! -d "$dir/browser" ]]; then
      continue
    fi
    # BSD realpath has no -m, and the path exists by now anyway.
    real=$(realpath "$dir" 2>/dev/null || realpath -m "$dir" 2>/dev/null || echo "$dir")

    local dup=no s
    for s in "${seen[@]:-}"; do
      [[ "$s" == "$real" ]] && dup=yes && break
    done
    [[ "$dup" == yes ]] && continue
    seen+=("$real")

    ver=$(sed -n 's/^Version=//p' "$real/application.ini" 2>/dev/null | head -1)
    name=$(sed -n 's/^Name=//p' "$real/application.ini" 2>/dev/null | head -1)
    [[ -z "$ver" ]] && ver="?"
    [[ -z "$name" ]] && name="Firefox"

    # Match the marker, but also plain "swipe-anim" so installs made before the
    # marker existed are still recognised.
    installed=no
    if [[ -f "$real/mozilla.cfg" ]] &&
      grep -qE "$MARKER|swipe-anim" "$real/mozilla.cfg" 2>/dev/null; then
      installed=yes
    fi
    # Probed rather than read off the mode bits, and asked of the deepest
    # directory that exists: on macOS defaults/pref is ours to create.
    writable=no
    if swipe_probe_writable "$real" &&
      swipe_probe_writable "$(swipe_nearest_existing "$real/defaults/pref")"; then
      writable=yes
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$real" "$ver" "$name" "$installed" "$writable"
  done < <(swipe_candidate_dirs)
}

# The .app for display, the inner directory for everything else.
swipe_display_dir() {
  if [[ "$SWIPE_OS" == Darwin ]]; then
    swipe_bundle_of "$1"
  else
    printf '%s\n' "$1"
  fi
}

# The application responsible for this shell, in TCC's sense: not the process
# that writes the file but the GUI app the permission is recorded against. Walks
# up the process tree to the first ancestor living inside an .app bundle, which
# is the name the user has to look for in System Settings.
swipe_responsible_app() {
  local pid=$$ comm app guard=0
  while [[ -n "$pid" && "$pid" -gt 1 && "$guard" -lt 24 ]]; do
    guard=$((guard + 1))
    comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    case "$comm" in
      *.app/Contents/MacOS/*)
        app="${comm%%.app/Contents/MacOS/*}"
        printf '%s\n' "${app##*/}"
        return 0
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  done
  return 1
}

# Why a directory inside a Firefox.app could not be written, in the user's terms.
# The distinction that matters: App Management denies the write while the
# permission bits still say yes, so mode-writable-but-refused is the signature of
# TCC and nothing else. sudo is never the answer to that one -- and is a bad
# answer to the other, since root-owned files inside a user-owned bundle break
# Firefox's own updater.
swipe_explain_unwritable() {
  local dir="$1" bundle app
  bundle=$(swipe_bundle_of "$dir")

  if [[ "$SWIPE_OS" != Darwin ]]; then
    echo "  not writable as this user; re-run with sudo" >&2
    return
  fi

  if [[ -w "$dir" || -w "$(swipe_nearest_existing "$dir")" ]]; then
    app=$(swipe_responsible_app || echo "your terminal application")
    cat >&2 <<EOF

macOS refused the write, although the permissions allow it. That is App
Management: modifying another app's bundle needs it, and sudo does not grant it.

  System Settings > Privacy & Security > App Management > enable $app

Then quit $app completely and reopen it -- a running process does not pick up
the new grant -- and run this again.
EOF
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      cat >&2 <<'EOF'

You are over SSH, where there is no application to grant this to. Run the
installer from a terminal on the machine itself.
EOF
    fi
    return
  fi

  cat >&2 <<EOF

$bundle is not writable by you.

Do not reach for sudo: files owned by root inside a bundle owned by someone else
make every future Firefox update fail. Fix the ownership instead:

  sudo chown -R "\$(id -un)" "$bundle"
EOF
}

# Conditions that make a macOS bundle the wrong thing to write into at all,
# rather than merely difficult. Both are cheap to check and expensive to hit.
swipe_check_bundle_sane() {
  local dir="$1" bundle
  bundle=$(swipe_bundle_of "$dir")
  [[ "$SWIPE_OS" == Darwin ]] || return 0

  # Modifying a *quarantined* notarized bundle is the one documented way to earn
  # "Firefox is damaged and can't be opened". Launching it once clears the flag.
  if xattr "$bundle" 2>/dev/null | grep -q '^com\.apple\.quarantine$'; then
    echo "SKIP $bundle (still quarantined; launch Firefox once, then re-run)" >&2
    return 1
  fi

  # Running straight from the mounted .dmg.
  if df "$bundle" 2>/dev/null | tail -1 | grep -q '/Volumes/'; then
    if ! swipe_probe_writable "$dir" && [[ ! -w "$dir" ]]; then
      echo "SKIP $bundle (read-only volume; drag Firefox to /Applications first)" >&2
      return 1
    fi
  fi
  return 0
}

# Compares dotted versions: returns 0 if $1 >= $2.
swipe_version_ge() {
  [[ "$1" == "?" ]] && return 0
  local a b
  a=$(printf '%s' "$1" | sed 's/[^0-9.].*$//')
  b=$(printf '%s' "$2" | sed 's/[^0-9.].*$//')
  [[ -z "$a" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" == "$b" ]]
}

# Presents the detected installations and reads a selection from the terminal.
#   $1 = "install" | "uninstall"   (changes wording and which rows are offered)
#   $2 = minimum supported version (install only; "" to skip the check)
# Selected paths are returned in the global array SWIPE_SELECTED.
swipe_choose_installs() {
  local mode="$1" minver="${2:-}"
  SWIPE_SELECTED=()

  local records=() rec
  while IFS= read -r rec; do
    records+=("$rec")
  done < <(swipe_detect_installs)

  if ((${#records[@]} == 0)); then
    echo "No Firefox installations found." >&2
    echo "Pass one explicitly:  $0 /path/to/firefox" >&2
    echo "Or set SWIPE_EXTRA_DIRS to additional locations to search." >&2
    return 1
  fi

  # For uninstall, only offer installations that actually have it installed.
  local offered=()
  for rec in "${records[@]}"; do
    local inst
    inst=$(printf '%s' "$rec" | cut -f4)
    if [[ "$mode" == uninstall && "$inst" != yes ]]; then
      continue
    fi
    offered+=("$rec")
  done

  if ((${#offered[@]} == 0)); then
    echo "Found ${#records[@]} Firefox installation(s), but none have swipe navigation installed." >&2
    return 1
  fi

  echo
  echo "Detected Firefox installations:"
  echo
  local i=1
  for rec in "${offered[@]}"; do
    local p v n inst w note=""
    p=$(printf '%s' "$rec" | cut -f1)
    v=$(printf '%s' "$rec" | cut -f2)
    n=$(printf '%s' "$rec" | cut -f3)
    inst=$(printf '%s' "$rec" | cut -f4)
    w=$(printf '%s' "$rec" | cut -f5)
    [[ "$inst" == yes ]] && note="${note}  [already installed]"
    if [[ "$w" == no ]]; then
      # On macOS the obstacle is App Management far more often than ownership,
      # and "needs root" would send the user somewhere sudo cannot help.
      if [[ "$SWIPE_OS" == Darwin ]]; then
        note="${note}  [not writable]"
      else
        note="${note}  [needs root]"
      fi
    fi
    if [[ "$mode" == install && -n "$minver" ]] && ! swipe_version_ge "$v" "$minver"; then
      note="${note}  [UNSUPPORTED: needs $minver+]"
    fi
    printf '  %d) %-52s %s %s%s\n' "$i" "$(swipe_display_dir "$p")" "$n" "$v" "$note"
    i=$((i + 1))
  done
  echo

  local prompt="Select installation(s) to ${mode} [e.g. 1  or  1,3  or  all]: "
  local reply=""
  if [[ -n "${SWIPE_ASSUME_ALL:-}" ]]; then
    reply="all"
    echo "${prompt}all  (SWIPE_ASSUME_ALL set)"
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt" reply < /dev/tty || true
  else
    echo "Not running interactively and SWIPE_ASSUME_ALL is unset." >&2
    echo "Pass paths explicitly, or set SWIPE_ASSUME_ALL=1." >&2
    return 1
  fi

  reply=$(printf '%s' "$reply" | tr -d '[:space:]')
  if [[ -z "$reply" || "$reply" == q || "$reply" == Q ]]; then
    echo "Nothing selected." >&2
    return 1
  fi

  local picks=()
  if [[ "$reply" == all || "$reply" == a ]]; then
    for rec in "${offered[@]}"; do
      picks+=("$(printf '%s' "$rec" | cut -f1)")
    done
  else
    local IFS=','
    local tok
    for tok in $reply; do
      if ! [[ "$tok" =~ ^[0-9]+$ ]] || ((tok < 1 || tok > ${#offered[@]})); then
        echo "Invalid selection: $tok" >&2
        return 1
      fi
      picks+=("$(printf '%s' "${offered[$((tok - 1))]}" | cut -f1)")
    done
  fi

  SWIPE_SELECTED=("${picks[@]}")
  return 0
}
