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

# --list changes nothing and needs no privileges, which makes it the safe way to
# see what detection found -- and the first thing to ask for in a bug report.
# The counterpart to install.ps1 -List.
if [[ "${1:-}" == --list || "${1:-}" == -l ]]; then
  found=0
  while IFS= read -r rec; do
    found=1
    p=$(printf '%s' "$rec" | cut -f1)
    v=$(printf '%s' "$rec" | cut -f2)
    n=$(printf '%s' "$rec" | cut -f3)
    inst=$(printf '%s' "$rec" | cut -f4)
    w=$(printf '%s' "$rec" | cut -f5)
    note=""
    [[ "$inst" == yes ]] && note="${note}  [already installed]"
    [[ "$w" == no ]] && note="${note}  [not writable]"
    swipe_version_ge "$v" "$MIN_FIREFOX_VERSION" ||
      note="${note}  [UNSUPPORTED: needs $MIN_FIREFOX_VERSION+]"
    printf '  %-52s %s %s%s\n' "$(swipe_display_dir "$p")" "$n" "$v" "$note"
  done < <(swipe_detect_installs)
  ((found)) || { echo "No Firefox installations found." >&2; exit 1; }
  exit 0
fi

# Explicit paths win over detection. A macOS user names the bundle, not the
# directory inside it, so accept either.
if (($# > 0)); then
  SWIPE_SELECTED=()
  for arg in "$@"; do
    SWIPE_SELECTED+=("$(swipe_normalize_dir "$arg")")
  done
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
  swipe_check_bundle_sane "$ff_dir" || return 1

  local pref_dir="$ff_dir/defaults/pref"

  local ver
  ver=$(sed -n 's/^Version=//p' "$ff_dir/application.ini" | head -1)
  if ! swipe_version_ge "${ver:-?}" "$MIN_FIREFOX_VERSION"; then
    echo "SKIP $ff_dir (Firefox ${ver:-unknown}; needs $MIN_FIREFOX_VERSION+)" >&2
    return 1
  fi
  # Probed, not read off the mode bits: on macOS they are not the deciding
  # factor, and defaults/pref may not exist yet to have any.
  if ! swipe_probe_writable "$ff_dir" ||
    ! swipe_probe_writable "$(swipe_nearest_existing "$pref_dir")"; then
    echo "SKIP $(swipe_display_dir "$ff_dir") (not writable)" >&2
    swipe_explain_unwritable "$ff_dir"
    return 1
  fi

  # defaults/pref ships with Firefox on Linux and Windows, but not on macOS:
  # channel-prefs.js, the file that used to put it there, moved into
  # ChannelPrefs.framework. Firefox still reads the directory if it exists, so
  # creating it is all that is needed -- but note it in the manifest, because a
  # directory this script created is one it should also be able to remove.
  local created=() d
  for d in "$ff_dir/defaults" "$pref_dir"; do
    [[ -d "$d" ]] || created+=("$d")
  done

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

  if ((${#created[@]} > 0)); then
    mkdir -p "$pref_dir"
    for d in "${created[@]}"; do
      # 0755 and owned by whoever owns the bundle, deliberately. Firefox's
      # removed-files tells its updater to rmdir Contents/Resources/defaults/,
      # and RemoveDir::Prepare treats a directory it cannot write as a FATAL
      # update error -- so a root-owned defaults/ inside a user-owned bundle
      # would break every future Firefox update. This is the reason the macOS
      # path never asks for sudo.
      chmod 0755 "$d"
      echo "mkdir=$d" >> "$manifest"
    done
  fi

  local target_cfg="$ff_dir/mozilla.cfg"
  local target_pref="$pref_dir/local-settings.js"
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

  # If this did run as root anyway -- an MDM-managed bundle, or a user who
  # insisted -- hand what was created back to the bundle's owner, for the
  # updater reason above.
  if [[ "$SWIPE_OS" == Darwin && "${EUID:-$(id -u)}" -eq 0 ]]; then
    local owner
    owner=$(stat -f '%u:%g' "$(swipe_bundle_of "$ff_dir")" 2>/dev/null || true)
    if [[ -n "$owner" ]]; then
      chown "$owner" "$target_cfg" "$target_pref" 2>/dev/null || true
      for d in ${created[@]+"${created[@]}"}; do
        chown "$owner" "$d" 2>/dev/null || true
      done
    fi
  fi

  ln -sfn "$backup" "$BACKUP_ROOT/latest"
  echo "OK   $(swipe_display_dir "$ff_dir")  (Firefox $ver)"
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
  if [[ "$SWIPE_OS" == Darwin ]]; then
    cat <<EOF

Payload (edit freely, no privileges needed, just restart Firefox):
  $PAYLOAD

Manifests: $BACKUP_ROOT
Roll back with: $HERE/uninstall.sh

Quit Firefox completely, then start it again and swipe horizontally with two
fingers.

This needs macOS's own swipe setting to be a two-finger one:
  System Settings > Trackpad > More Gestures > Swipe between pages
  = "Scroll left or right with two fingers" (or "Swipe with two or three fingers")
Set to three fingers, macOS never sends the continuous gesture and Firefox
navigates instantly with no animation. Check from the Browser Console with:
  SwipeAnim.health(window).swipeGestureAvailable

NOTE: writing into Firefox.app invalidates its code signature, so
      \`codesign --verify\` will report added resources from now on. Firefox
      still launches -- Gatekeeper only enforces this on a quarantined app --
      and this is Mozilla's own documented way to deploy autoconfig on macOS.
      Firefox's own updates keep these files; \`brew upgrade --cask firefox\`
      replaces the whole bundle and does not, so re-run this afterwards.
EOF
  else
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
fi
((ok > 0)) || exit 1
