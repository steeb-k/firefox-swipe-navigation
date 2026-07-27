#!/usr/bin/env bash
# Remove the swipe navigation animation from one or more Firefox installations.
#
# Uses the manifest written by install.sh where one exists, so files that were
# already present before installing are restored rather than deleted. Falls back
# to removing only files carrying this project's marker.
#
# Usage:
#   sudo ./uninstall.sh                      # detect installs and choose
#   sudo ./uninstall.sh /path/to/firefox ... # uninstall from the given paths
#   SWIPE_ASSUME_ALL=1 sudo ./uninstall.sh   # non-interactive, all detected
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

BACKUP_ROOT="${SWIPE_BACKUP_ROOT:-$HERE/backups}"

if (($# > 0)); then
  SWIPE_SELECTED=()
  for arg in "$@"; do
    SWIPE_SELECTED+=("$(swipe_normalize_dir "$arg")")
  done
else
  swipe_choose_installs uninstall "" || exit 1
fi

echo
echo "About to remove swipe navigation from:"
for d in "${SWIPE_SELECTED[@]}"; do
  echo "  $(swipe_display_dir "$d")"
done
echo
if [[ -z "${SWIPE_ASSUME_ALL:-}" && -r /dev/tty ]]; then
  read -r -p "Proceed? [y/N] " confirm < /dev/tty || true
  case "$confirm" in
    y | Y | yes | YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Finds the newest manifest that refers to a given installation directory.
find_manifest_for() {
  local ff_dir="$1" m best=""
  [[ -d "$BACKUP_ROOT" ]] || return 1
  while IFS= read -r m; do
    if grep -qxF "ff_dir=$ff_dir" "$m" 2>/dev/null; then
      best="$m"
    fi
  done < <(find "$BACKUP_ROOT" -name manifest.txt -type f 2>/dev/null | sort)
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

uninstall_one() {
  local ff_dir="$1"
  local cfg="$ff_dir/mozilla.cfg"
  local pref="$ff_dir/defaults/pref/local-settings.js"

  if ! swipe_probe_writable "$ff_dir"; then
    echo "SKIP $(swipe_display_dir "$ff_dir") (not writable)" >&2
    swipe_explain_unwritable "$ff_dir"
    return 1
  fi

  local manifest
  manifest=$(find_manifest_for "$ff_dir" || true)

  if [[ -n "$manifest" ]]; then
    local backup
    backup=$(dirname "$manifest")
    echo "  using manifest $manifest"
    local line path orig
    local made=()
    while IFS= read -r line; do
      case "$line" in
        added=* | replaced=*)
          path="${line#*=}"
          [[ -e "$path" ]] && rm -fv "$path"
          ;;
        existed=*)
          path="${line#*=}"
          orig="$backup/$(basename "$path").orig"
          if [[ -f "$orig" ]]; then
            echo "  restoring pre-existing $path"
            install -m 0644 "$orig" "$path"
          else
            echo "  WARNING: no backup for pre-existing $path; leaving it alone" >&2
          fi
          ;;
        mkdir=*)
          made+=("${line#*=}")
          ;;
      esac
    done < "$manifest"

    # Directories this project created, which on macOS means defaults/ and
    # defaults/pref inside the app bundle. Deepest first, and only while empty:
    # rmdir rather than rm -r, so anything that turned up in the meantime -- a
    # second autoconfig deployment, say -- stops the removal instead of going
    # with it.
    local i
    for ((i = ${#made[@]} - 1; i >= 0; i--)); do
      path="${made[$i]}"
      if [[ -d "$path" ]]; then
        if rmdir "$path" 2>/dev/null; then
          echo "  removed created directory $path"
        else
          echo "  leaving $path (not empty)"
        fi
      fi
    done
  else
    # No manifest: only touch files that carry our marker, never anything else.
    echo "  no manifest found; removing marked files only"
    if [[ -f "$cfg" ]] && grep -qE "$MARKER|swipe-anim" "$cfg" 2>/dev/null; then
      rm -fv "$cfg"
    elif [[ -f "$cfg" ]]; then
      echo "  leaving $cfg (not ours: no marker)" >&2
    fi
    # local-settings.js carries no marker of its own, so match on its contents.
    if [[ -f "$pref" ]] && grep -q 'general.config.filename' "$pref" 2>/dev/null &&
      grep -q 'mozilla.cfg' "$pref" 2>/dev/null; then
      rm -fv "$pref"
    fi
  fi

  # Firefox ships no defaults/ inside the bundle on macOS, so an empty one can
  # only be ours -- which makes this safe without a manifest saying so, and
  # covers the case a manifest cannot: install twice and only the first run
  # recorded creating the directories, but it is the second run's manifest that
  # the uninstaller finds.
  if [[ "$SWIPE_OS" == Darwin ]]; then
    rmdir "$ff_dir/defaults/pref" 2>/dev/null && echo "  removed $ff_dir/defaults/pref"
    rmdir "$ff_dir/defaults" 2>/dev/null && echo "  removed $ff_dir/defaults"
  fi

  echo "OK   $(swipe_display_dir "$ff_dir")"
  return 0
}

ok=0
fail=0
for dir in "${SWIPE_SELECTED[@]}"; do
  if uninstall_one "$dir"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

echo
echo "Removed from $ok installation(s); $fail skipped."
cat <<'EOF'

Restart Firefox to return to its stock swipe behaviour.

The preferences the script set at runtime (widget.swipe.pixel-size,
widget.swipe.velocity-twitch-tolerance, widget.swipe.success-velocity-contribution)
are cleared when it unloads. To clear them by hand, reset them in about:config.
EOF
