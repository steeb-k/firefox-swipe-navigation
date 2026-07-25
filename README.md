# firefox-swipe-navigation

Safari-style 1:1 back/forward swipe animations for Firefox on Linux.

Firefox already tracks a two-finger horizontal trackpad swipe continuously — it
just slides a small arrow indicator across the viewport rather than moving the
page. This replaces the arrow with the actual pages: the previous page sits
still underneath while the current one slides off it, tracking your fingers
pixel for pixel, exactly as Safari and GNOME Web do.

It is a drop-in: two small files in the Firefox installation directory plus one
script in your home directory. No patched build, no rebuilt Firefox, no
extension.

## Requirements

- **Firefox 111 or newer.** Bug 1799563 (January 2023, first shipped in 111)
  rewrote `gHistorySwipeAnimation` into the form this replaces, including the
  `updateAnimation(delta)` entry point everything here depends on. The installer
  refuses to touch anything older.
- Linux/GTK. Touchpad swipe-to-navigate shipped on Linux in Firefox 106
  (bug 1790580), so 111 is the binding constraint.
- Developed and verified against **Firefox 152**. Versions between 111 and 152
  should work but are untested.
- A trackpad that produces two-finger horizontal pan gestures.
- Write access to the Firefox installation directory (i.e. `sudo`) once.

## Install

```sh
git clone https://github.com/steeb-k/firefox-swipe-navigation.git
cd firefox-swipe-navigation
sudo ./install.sh
```

With no arguments the installer searches the usual locations — `/usr/lib`,
`/usr/lib64`, `/usr/local/lib`, `/opt`, Snap, Flatpak and a few paths under your
home directory — and lists what it finds with each version, so you can pick one
or several:

```
Detected Firefox installations:

  1) /usr/lib/firefox                     Firefox 152.0.4
  2) /usr/lib/firefox-developer-edition    Firefox 153.0    [already installed]

Select installation(s) to install [e.g. 1  or  1,3  or  all]:
```

Anything too old, unwritable, or already carrying an install is labelled as such.
Or skip the prompt entirely:

```sh
sudo ./install.sh /path/to/firefox /another/firefox   # explicit paths
SWIPE_ASSUME_ALL=1 sudo ./install.sh                  # every detected install
SWIPE_EXTRA_DIRS="/custom/path" sudo ./install.sh     # widen the search
```

Then quit Firefox completely and restart it.

Only the install step needs root. `swipe-anim.js` stays in the cloned
repository and is re-read on every window open, so to iterate you edit it and
restart Firefox — no root, no reinstall.

## Uninstall

```sh
sudo ./uninstall.sh
```

This lists only the installations that actually have it installed, asks which to
clean, and confirms before touching anything. It accepts the same explicit paths
and `SWIPE_ASSUME_ALL=1` as the installer.

The install is purely additive: it writes only `mozilla.cfg` and
`defaults/pref/local-settings.js`, refuses to overwrite either without first
saving a `.orig` copy, and records a manifest per installation of exactly what it
touched. `uninstall.sh` reverses precisely that, restoring any pre-existing file
byte-for-byte. If a manifest is missing it removes only files carrying this
project's marker, and leaves anything unrecognised alone.

To disable it temporarily without uninstalling, set
`widget.disable-swipe-tracker` to `true` in `about:config`. That turns off
Firefox's swipe handling entirely, this animation included.

## How it works

Firefox's gesture plumbing is already in place and already reports a continuous
progress value to the front end. `widget/SwipeTracker.cpp` converts trackpad pan
events into `MozSwipeGestureStart` / `Update` / `End`, and
`browser/base/content/browser-gestureSupport.js` forwards each update's delta to
`gHistorySwipeAnimation.updateAnimation()`. That object is plain JavaScript
living on the chrome window, so it can be replaced at runtime.

This project does exactly that, via Firefox's `autoconfig` mechanism — the
supported way to run privileged JavaScript at startup:

- `defaults/pref/local-settings.js` points Firefox at `mozilla.cfg` and disables
  the autoconfig sandbox.
- `mozilla.cfg` is a small loader that reads `swipe-anim.js` into each browser
  window and calls `SwipeAnim.install(window)`.
- `swipe-anim.js` overrides the four `gHistorySwipeAnimation` entry points.

Page imagery comes from `WindowGlobalParent.drawSnapshot()`, captured once per
navigation while you are sitting on a page and cached against its session
history index — the same approach as Safari's `ViewSnapshotStore` and Chrome for
Android's `NavigationEntryScreenshot`. Capture costs roughly 13–17 ms, runs
asynchronously in the content process, and is never on the gesture's critical
path.

During a gesture two containers are inserted into the browser stack: an underlay
that paints below the `<browser>` and an overlay that paints above it. This is
what allows the two directions to differ:

- **Back is an uncover.** The previous page is stationary in the underlay; the
  live page slides off it.
- **Forward is a cover.** The next page slides in from the overlay, on top of a
  stationary current page.

Whichever page is underneath is dimmed, and the moving page carries an edge
shadow, so the two read as stacked rather than as a filmstrip.

On release the gesture is finished off with snapshots rather than by continuing
to move the live `<browser>` — that browser is already navigating, so it would
visibly change content mid-slide. The destination snapshot is held until the new
page actually paints, which also removes the flash that would otherwise appear
before first paint.

## Configuration

All read live from `about:config`.

| Preference | Default | Meaning |
| --- | --- | --- |
| `swipeAnim.parallax` | `0` | `0` keeps the incoming page perfectly still. `1` locks both pages together for a filmstrip look. Values around `0.15`–`0.3` give a subtle parallax. |
| `swipeAnim.dim` | `0.28` | Peak dim opacity applied to whichever page is underneath. `0` disables. |
| `swipeAnim.shadow` | `true` | Edge shadow on the moving page. |
| `swipeAnim.commitMs` | `260` | Duration of the settle animation after you let go. |
| `swipeAnim.fullTraverse` | `true` | Keeps `widget.swipe.pixel-size` matched to the viewport width (see below). |
| `swipeAnim.positionalCommit` | `true` | Commit/cancel decided by where you release rather than by gesture velocity (see below). |

### Two Firefox internals worth knowing about

Both of these are why the defaults above exist.

**`widget.swipe.pixel-size` bounds how far the page can travel.**
`SwipeTracker` divides finger displacement by this preference and clamps the
result to `[-1, 1]`, so the page can never move further than `pixel-size` CSS
pixels. The Linux default is `1100`, narrower than most viewports, which leaves
the page stranded partway across the screen. Setting it to the viewport width is
the one value where 1:1 tracking and a complete traverse are simultaneously
true, and `swipeAnim.fullTraverse` keeps it there as the window resizes. A side
effect is that the commit threshold — a hardcoded 25% in `SwipeTracker.cpp` —
becomes 25% of the window width rather than a fixed distance.

**Reversing direction makes Firefox report a deliberately false position.**
When `ComputeSwipeSuccess()` decides a swipe will fail, `ProcessEvent` clamps the
reported delta to `0.999 × 0.25` so the UI does not imply that navigation is
about to happen. Sensible for an arrow indicator; for a page tracking your
fingers it is an instant jump to 25% of the screen. The trigger is a velocity
check at the very top of `ComputeSwipeSuccess()`, whose tolerance defaults to
`0.0000001` — effectively zero, so any reverse motion trips it. Note that
`widget.swipe.success-velocity-contribution` does *not* help, because that early
return fires before the contribution is read. `swipeAnim.positionalCommit`
neutralises the velocity terms so the decision is purely positional, which makes
the clamp unreachable.

## Troubleshooting

Two helpers are available in the Browser Console (`Ctrl+Shift+J`):

```js
SwipeAnim.health(window)   // stuck state, leftover nodes, swallowed errors, recent gestures
SwipeAnim.reset(window)    // clear state and remove leftovers, keeping the snapshot cache
```

`health()` reports whether the overrides are still installed, any exceptions
that were caught and swallowed, snapshot capture failures, and a log of recent
gestures including which directions had a cached snapshot.

If a destination page has no cached snapshot — the first visit in a session, or
after the cache has evicted it — that gesture falls back to Firefox's own arrow
indicator rather than showing a blank card.

## Known limitations

- Linux/GTK only. The same entry points exist on macOS and Windows, but nothing
  here has been tested on either.
- The snapshot cache holds six entries, evicting whichever is furthest from the
  current position. Swiping to a page beyond that falls back to the arrows.
- A snapshot taken at a different window size is anchored top-left and cropped
  rather than stretched, so a resized window may show a filled strip along an
  edge. The fill colour is sampled from the snapshot to blend in.
- Snapshots are static images. Video, animation and any content that changed
  since capture will not be live during the gesture.
- Because the installed files are not owned by your package manager, they
  survive Firefox upgrades. Uninstall before a major version change, or re-check
  afterwards.
