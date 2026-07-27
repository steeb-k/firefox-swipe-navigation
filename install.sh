#!/usr/bin/env bash
# Install the swipe navigation animation into one or more Firefox installations.
#
# Purely additive: it refuses to overwrite anything it has not backed up first,
# and writes a manifest per installation that uninstall.sh uses to reverse
# exactly this change.
#
# Usage:
#   sudo ./install.sh                      # detect installs and choose
#   sudo ./install.sh /path/to/firefox ... # install into the given paths
#   SWIPE_ASSUME_ALL=1 sudo ./install.sh   # non-interactive, all detected
#
# Environment:
#   SWIPE_EXTRA_DIRS   extra locations to include when detecting
#   SWIPE_BACKUP_ROOT  where to write manifests (default: ./backups)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MIN_FIREFOX_VERSION=111

PAYLOAD="$HERE/swipe-anim.js"
TEMPLATE="$HERE/autoconfig/mozilla.cfg.in"
PREFS_SRC="$HERE/autoconfig/local-settings.js"
BACKUP_ROOT="${SWIPE_BACKUP_ROOT:-$HERE/backups}"

for f in "$PAYLOAD" "$TEMPLATE" "$PREFS_SRC"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

# Explicit paths win over detection.
if (($# > 0)); then
  SWIPE_SELECTED=("$@")
else
  swipe_choose_installs install "$MIN_FIREFOX_VERSION" || exit 1
fi

install_one() {
  local ff_dir="$1"

  if [[ ! -d "$ff_dir" ]]; then
    echo "SKIP $ff_dir (not a directory)" >&2
    return 1
  fi
  if [[ ! -f "$ff_dir/application.ini" ]]; then
    echo "SKIP $ff_dir (no application.ini; not a Firefox installation)" >&2
    return 1
  fi
  if [[ ! -d "$ff_dir/defaults/pref" ]]; then
    echo "SKIP $ff_dir (no defaults/pref)" >&2
    return 1
  fi

  local ver
  ver=$(sed -n 's/^Version=//p' "$ff_dir/application.ini" | head -1)
  if ! swipe_version_ge "${ver:-?}" "$MIN_FIREFOX_VERSION"; then
    echo "SKIP $ff_dir (Firefox ${ver:-unknown}; needs $MIN_FIREFOX_VERSION+)" >&2
    return 1
  fi
  if [[ ! -w "$ff_dir" || ! -w "$ff_dir/defaults/pref" ]]; then
    echo "SKIP $ff_dir (not writable; re-run with sudo)" >&2
    return 1
  fi

  local stamp backup manifest
  stamp="$(date +%Y%m%d-%H%M%S)-$(printf '%s' "$ff_dir" | tr -c 'A-Za-z0-9' '_' | tail -c 40)"
  backup="$BACKUP_ROOT/$stamp"
  manifest="$backup/manifest.txt"
  mkdir -p "$backup"
  {
    echo "# swipe navigation install manifest"
    echo "# created: $stamp"
    echo "ff_dir=$ff_dir"
    echo "payload=$PAYLOAD"
    echo "firefox_version=$ver"
  } > "$manifest"

  local target_cfg="$ff_dir/mozilla.cfg"
  local target_pref="$ff_dir/defaults/pref/local-settings.js"
  local target
  for target in "$target_cfg" "$target_pref"; do
    if [[ -e "$target" ]]; then
      if grep -q "$MARKER" "$target" 2>/dev/null; then
        # One of ours from a previous run; replacing it is not destructive.
        echo "replaced=$target" >> "$manifest"
      else
        echo "  backing up pre-existing $target"
        cp -a "$target" "$backup/$(basename "$target").orig"
        echo "existed=$target" >> "$manifest"
      fi
    else
      echo "added=$target" >> "$manifest"
    fi
  done

  # Bake the payload's absolute path into the loader, as a file: URL. A POSIX
  # path is already absolute-rooted, so file:// plus the leading slash of the
  # path is the required three.
  sed "s|@PAYLOAD_URL@|file://$PAYLOAD|g" "$TEMPLATE" > "$backup/mozilla.cfg.generated"
  install -m 0644 "$backup/mozilla.cfg.generated" "$target_cfg"
  install -m 0644 "$PREFS_SRC" "$target_pref"

  ln -sfn "$backup" "$BACKUP_ROOT/latest"
  echo "OK   $ff_dir  (Firefox $ver)"
  return 0
}

ok=0
fail=0
for dir in "${SWIPE_SELECTED[@]}"; do
  if install_one "$dir"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

echo
echo "Installed into $ok installation(s); $fail skipped."
if ((ok > 0)); then
  cat <<EOF

Payload (edit freely, no root needed, just restart Firefox):
  $PAYLOAD

Manifests: $BACKUP_ROOT
Roll back with: sudo $HERE/uninstall.sh

Restart Firefox completely, then swipe horizontally with two fingers.

NOTE: the package manager does not own the installed files, so they survive a
      Firefox upgrade and could misbehave on a future version. Uninstall before
      a major update, or re-check afterwards.
EOF
fi
((ok > 0)) || exit 1
