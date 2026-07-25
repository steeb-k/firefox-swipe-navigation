# Shared helpers for install.sh / uninstall.sh: finding Firefox installations
# and letting the user choose among them.
# shellcheck shell=bash

MARKER="firefox-swipe-navigation-marker"

# Places a Firefox installation directory commonly lives. Globs are fine; each
# candidate is validated by the presence of application.ini, and duplicates are
# collapsed by real path (many distros symlink /usr/lib64 -> /usr/lib).
swipe_candidate_dirs() {
  local homedir="${HOME:-/root}"
  # When running under sudo, also look in the invoking user's home.
  if [[ -n "${SUDO_USER:-}" ]]; then
    local sudo_home
    sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
    [[ -n "$sudo_home" ]] && homedir="$sudo_home"
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

# Emits one TAB-separated record per detected installation:
#   path <TAB> version <TAB> name <TAB> installed(yes|no) <TAB> writable(yes|no)
swipe_detect_installs() {
  local seen=() dir real ver name installed writable
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ -d "$dir" ]] || continue
    [[ -f "$dir/application.ini" ]] || continue
    real=$(realpath -m "$dir" 2>/dev/null || echo "$dir")

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
    writable=no
    [[ -w "$real" && -w "$real/defaults/pref" ]] && writable=yes

    printf '%s\t%s\t%s\t%s\t%s\n' "$real" "$ver" "$name" "$installed" "$writable"
  done < <(swipe_candidate_dirs)
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
    [[ "$w" == no ]] && note="${note}  [needs root]"
    if [[ "$mode" == install && -n "$minver" ]] && ! swipe_version_ge "$v" "$minver"; then
      note="${note}  [UNSUPPORTED: needs $minver+]"
    fi
    printf '  %d) %-52s %s %s%s\n' "$i" "$p" "$n" "$v" "$note"
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
