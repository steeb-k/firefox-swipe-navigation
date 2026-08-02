# firefox-swipe-navigation

Safari-style 1:1 back/forward swipe animations for Firefox on Linux, Windows and
macOS.

<video src="https://github.com/user-attachments/assets/b4e8654e-5ef2-4e27-807b-300b73f6d8fc" controls muted></video>

Swiping back and forth, in real time. The previous page sits still underneath
while the current one slides off it, tracking the gesture pixel for pixel, and a
page scrolled halfway down comes back exactly where it was left. The two dots
stand in for the fingers on the trackpad.

On Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.sh | bash
```

On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.ps1 | iex
```

Then quit Firefox completely and restart it. Requires Firefox 111+. On Linux and
Windows it needs one privilege escalation — sudo, or a UAC prompt — which the
scripts ask for themselves at the one step that needs it, so do **not** run
either one elevated. On macOS it needs no escalation at all, and running it with
`sudo` is actively wrong: see [macOS](#macos).

It clones this repository — to `~/.local/share/firefox-swipe-navigation`, or
`%LOCALAPPDATA%\firefox-swipe-navigation` — and runs the installer, which lists
the Firefox installations it found and asks which to install into. The checkout
is permanent and yours: `swipe-anim.js` stays there and is re-read every time a
window opens, so you can edit it without root. Re-run the same line any time to
update.

On Windows git is optional. With git installed the checkout is a clone and
re-running the line is a `git pull`, which is what lets it keep your edits.
Without it the source is downloaded as a zip and re-running re-downloads;
since there is then no history to tell your changes from upstream's, a refresh
that would overwrite a file you have modified stops and says which file rather
than guessing.

If piping a script to a shell makes you uneasy — reasonably, since it asks for
privileges — read it first and run it separately:

```sh
curl -fsSL https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.sh -o get.sh
less get.sh
bash get.sh
```

```powershell
irm https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.ps1 -OutFile get.ps1
notepad get.ps1
powershell -ExecutionPolicy Bypass -File .\get.ps1
```

The `-ExecutionPolicy Bypass` in that last line is not incidental — see
[below](#why-every-windows-command-here-says--executionpolicy-bypass).

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
- Linux/GTK, Windows or macOS. Touchpad swipe-to-navigate shipped on Linux in
  Firefox 106 (bug 1790580), so 111 is the binding constraint everywhere.
- Developed and verified against **Firefox 152**, and since re-verified on
  **154** and **155**. Versions between 111 and 155 should work but are
  untested.
- **Firefox 155 changed how the payload has to be reached.** `loadSubScript` no
  longer accepts `file:` URLs, so an installation made before that change is
  silently inert on 155 — the browser starts perfectly with none of this in it.
  Re-running the install line updates the loader and fixes it.
- A trackpad that produces two-finger horizontal pan gestures. On Windows that
  means a Precision Touchpad: the gesture arrives through Direct Manipulation
  rather than GTK, but reaches the same `SwipeTracker` and the same front-end
  entry points. macOS reaches it too — the Cocoa-native swipe path that used to
  bypass `SwipeTracker` is gone from the tree.
- Write access to the Firefox installation directory once — `sudo` on Linux, an
  elevated shell on Windows, and on macOS neither. A per-user Firefox under
  `%LOCALAPPDATA%` is writable as yourself, and the Windows installer will not
  ask for elevation it does not need.

### macOS

Four things are specific to macOS, and the first two are the ones that bite.

**The OS has to be sending the gesture.** *System Settings → Trackpad → More
Gestures → Swipe between pages* must be **"Scroll left or right with two
fingers"** or **"Swipe with two or three fingers"**. On the three-finger setting,
or off, macOS sends no continuous swipe at all — Firefox navigates instantly with
no animation, and this project is installed and inert. It is the one platform
where that can happen: the `-moz-swipe-animation-enabled` media feature that
`gHistorySwipeAnimation` gates itself on is hardcoded true on GTK and Windows,
but on macOS reports `NSEvent.isSwipeTrackingFromScrollEventsEnabled`. Check it:

```js
SwipeAnim.health(window).swipeGestureAvailable
```

**Do not use `sudo`.** `/Applications/Firefox.app` belongs to whoever installed
it, so there is nothing to escalate for. Worse, `Contents/Resources/removed-files`
tells Firefox's updater to `rmdir Contents/Resources/defaults/`, and
`RemoveDir::Prepare` treats a directory it cannot write as a *fatal* update
error — so a root-owned `defaults/` inside a user-owned bundle breaks every
future Firefox update. The installer creates those directories as the bundle's
owner for exactly this reason.

If the write is refused anyway, that is **App Management**, not permissions:
macOS requires it to modify another app's bundle, `sudo` does not grant it, and a
denial is silent. Enable your terminal under *System Settings → Privacy &
Security → App Management*, then quit and reopen it — a running process does not
pick up the grant. The installer detects this case and names the application.

**Launch Firefox once before installing.** Modifying a bundle that still carries
`com.apple.quarantine` is the documented route to "Firefox is damaged and can't
be opened"; launching it once clears the flag. The installer refuses on a
quarantined bundle rather than risk it.

**The code signature.** Writing into `Contents/Resources` breaks the seal, so
`codesign --verify` and `spctl --assess` will report added resources from here
on. Firefox still launches — Gatekeeper enforces this on a quarantined app, and
this is Mozilla's own documented way to deploy autoconfig on macOS. Do not
re-sign to "fix" it: an ad-hoc signature replaces Mozilla's Developer ID, drops
the entitlements Firefox needs under the hardened runtime, and breaks the
same-team exemption its updater relies on.

Firefox's own updates **keep** these files: the macOS updater copies the whole
bundle to a staging directory with an empty skip-list before applying the update.
`brew upgrade --cask firefox` replaces the bundle wholesale and does not — re-run
the installer after one.

## Install

The one-liner at the top is the short version of this:

```sh
git clone https://github.com/steeb-k/firefox-swipe-navigation.git
cd firefox-swipe-navigation
sudo ./install.sh
```

```powershell
git clone https://github.com/steeb-k/firefox-swipe-navigation.git
cd firefox-swipe-navigation
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Clone wherever you like — the location is baked into the loader, so just don't
move or delete it afterwards.

With no arguments the installer searches the usual locations and lists what it
finds with each version, so you can pick one or several. On Linux that is
`/usr/lib`, `/usr/lib64`, `/usr/local/lib`, `/opt`, Snap, Flatpak and a few
paths under your home directory; on Windows it is whatever Firefox recorded
under `HKLM\SOFTWARE\Mozilla` and `HKCU\SOFTWARE\Mozilla`, plus a sweep of
Program Files and `%LOCALAPPDATA%` for an install that never registered itself;
on macOS it asks Spotlight for Mozilla bundles — the local equivalent of that
registry lookup — and sweeps `/Applications` and `~/Applications` as a backstop:

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
./install.sh --list                                   # show, change nothing
```

On macOS, drop the `sudo` and name the bundle — either the `.app` or the
`Contents/Resources` inside it works:

```sh
./install.sh /Applications/Firefox.app
```

The Windows installer takes the same three as switches, and adds two of its own:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 "C:\Program Files\Mozilla Firefox"
powershell -ExecutionPolicy Bypass -File .\install.ps1 -All        # every detected install
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ExtraDirs "D:\firefox"
powershell -ExecutionPolicy Bypass -File .\install.ps1 -List       # show, change nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Elevate    # ask UAC rather than report
```

`-List` needs no privileges and changes nothing, which makes it the safe way to
see what the detection found.

### Why every Windows command here says `-ExecutionPolicy Bypass`

A stock Windows install is set to `Restricted`, which refuses to run a `.ps1`
file at all — including one you wrote yourself, and including a script that
merely dot-sources another. `-ExecutionPolicy Bypass` lifts that for one
invocation without changing any policy on the machine, which is why every
command above carries it and why the installer launches with it internally.

The one-liner needs none of this: text piped to `iex` is a string rather than a
file, and that is a path execution policy does not govern. If you would rather
lift the restriction once and type less, that is
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` — a change to your account
rather than to a single command, so it is worth knowing you made it.

The one case nothing here can route around is an execution policy set by Group
Policy, since machine and user policy outrank a command line switch. On a
managed machine, that is a conversation with whoever manages it.

`SWIPE_ASSUME_ALL` and `SWIPE_EXTRA_DIRS` are forwarded by both one-liners, and
`SWIPE_HOME` changes where the checkout goes:

```sh
SWIPE_ASSUME_ALL=1 SWIPE_HOME=~/src/swipe bash get.sh
```

```powershell
$env:SWIPE_ASSUME_ALL = 1; $env:SWIPE_HOME = "D:\src\swipe"
irm https://raw.githubusercontent.com/steeb-k/firefox-swipe-navigation/main/get.ps1 | iex
```

Then quit Firefox completely and restart it.

Only the install step needs root. `swipe-anim.js` stays in the cloned
repository and is re-read on every window open, so to iterate you edit it and
restart Firefox — no root, no reinstall. Re-running the one-liner will refuse to
fast-forward over local edits rather than discard them, and tells you how to
keep or drop them.

## Uninstall

```sh
cd ~/.local/share/firefox-swipe-navigation   # wherever you cloned it
sudo ./uninstall.sh                          # on macOS, without the sudo
```

```powershell
cd $env:LOCALAPPDATA\firefox-swipe-navigation
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
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
  window and calls `SwipeAnim.install(window)`. It reaches the payload through a
  `resource:` substitution mapped onto the checkout's directory, because Firefox
  155 dropped `file:` from the schemes `loadSubScript` will accept — and no
  `file:` URL escapes that, including one inside the installation directory
  itself. `resource:` stays trusted, which is what lets the payload go on living
  in your home directory and go on being editable without root. The bare `file:`
  URL remains as a fallback, since every version through 154 takes either.
- `swipe-anim.js` overrides the four `gHistorySwipeAnimation` entry points.

Page imagery comes from `WindowGlobalParent.drawSnapshot()` — the same approach
as Safari's `ViewSnapshotStore` and Chrome for Android's
`NavigationEntryScreenshot`. Capture costs roughly 13–17 ms, runs asynchronously
in the content process, and is never on the gesture's critical path.

**Snapshots are cached per tab, keyed by session history entry rather than by
history index.** Indices are reused in two directions and neither one is
survivable with an index-keyed cache: every tab has an index 2, so one flat map
means swiping in one tab shows another tab's page; and within a single tab a new
navigation truncates forward history, so a later page inherits an index a
different page used to hold. `nsISHEntry.ID` identifies the entry itself, so a
reused index simply misses the cache instead of returning the wrong picture.

The ID is not used as a global key. Session restore reassigns IDs starting from
`Date.now()` with its uniqueness set scoped to a single tab's restore, so two
tabs restored in the same millisecond can hold equal IDs — harmless as long as
each tab's snapshots live in their own map, which is the other reason the cache
is per tab. Tabs are identified by `browser.permanentKey`, the handle that
survives a remoteness switch.

As a cross-check on the key — and as the only real guard on the fallback path
where an entry ID cannot be read — the destination snapshot's URL is compared
against the history entry's before animating to it. A mismatch means the bitmap
is of a different *page* rather than merely a different moment, so unlike a
stale snapshot it disqualifies the entry regardless of `swipeAnim.staleFallback`
and the gesture falls back to the arrows.

Snapshots are taken when a page settles after loading, when a navigation starts
(to refresh the page being left behind), when you switch to a tab, and at the
start of every gesture. Only the selected tab is ever captured — `drawSnapshot()`
on a backgrounded tab is not reliably a picture of anything — which is why
switching to a tab schedules one. That
last one is the reliable one: the page is still on screen and nothing is
navigating, so it cannot lose a race. It is what the release animation slides
off, and it leaves a correctly-scrolled entry behind for the return trip.

**`drawSnapshot()`'s rect is in document coordinates, not viewport
coordinates.** This is the single easiest thing to get wrong here. A rect of
`(0, 0, width, height)` reads as "what the user is looking at" and is in fact
"the top of the document" — a page scrolled halfway down snapshots as its own
header, so every swipe appears to navigate back to the top of the page. Passing
`null` is the documented way to request the currently visible viewport, and it
is scroll-aware without the parent process ever needing to know the scroll
offset. The fourth argument, `resetScrollPosition`, must stay `false` for the
same reason.

The pre-navigation refresh is a genuine race, separately: `drawSnapshot()` is an
asynchronous round trip to the content process, and a navigation can tear down
the `WindowGlobal` before it is serviced. Unlike WebKit, which snapshots from a
live layer tree in its UI process, there is no synchronous alternative. When it
loses, the cached entry still holds the page as of its last successful capture.
Rather than animate to an image known to be out of date, a failed refresh marks
its entry, and swiping to a marked entry falls back to the arrows.

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

All read live from `about:config`. None of them exist there until you make them:
Firefox only lists preferences that have actually been set, so searching for one
of these shows an empty result and a row offering to create it. Pick the type
from the table and add it. From the Browser Console it is one line, and takes
effect on the next gesture:

```js
Services.prefs.setBoolPref("swipeAnim.fingerDots", true)
```


| Preference | Default | Meaning |
| --- | --- | --- |
| `swipeAnim.parallax` | `0` | `0` keeps the incoming page perfectly still. `1` locks both pages together for a filmstrip look. Values around `0.15`–`0.3` give a subtle parallax. |
| `swipeAnim.dim` | `0.28` | Peak dim opacity applied to whichever page is underneath. `0` disables. |
| `swipeAnim.shadow` | `true` | Edge shadow on the moving page. |
| `swipeAnim.commitMs` | `260` | Duration of the settle animation after you let go. |
| `swipeAnim.fullTraverse` | `true` | Keeps `widget.swipe.pixel-size` matched to the viewport width (see below). |
| `swipeAnim.positionalCommit` | `true` | Commit/cancel decided by where you release rather than by gesture velocity (see below). |
| `swipeAnim.staleFallback` | `true` | Fall back to the arrows when the destination's snapshot is known to be out of date. Set to `false` to animate to it anyway, accepting that the scroll position may be wrong. |
| `swipeAnim.urlCheck` | `true` | Cross-check a destination snapshot's URL against the history entry before animating to it. Turn off only if `stats().urlMismatches` climbs during ordinary browsing, which would mean the check is misfiring rather than catching anything. |
| `swipeAnim.fingerDots` | `false` | Draw two dots that ride the gesture, standing in for the fingers on the trackpad. Meant for screencasts, which is why it is off by default. Where they sit is invented — nothing in the stack reports where your hand actually is — but how far they travel is the real gesture displacement, 1:1 with the page. |

### Two Firefox internals worth knowing about

Both of these are why the defaults above exist.

**`widget.swipe.pixel-size` bounds how far the page can travel.**
`SwipeTracker` divides finger displacement by this preference and clamps the
result to `[-1, 1]`, so the page can never move further than `pixel-size` CSS
pixels. The default is `1100` on Linux and Windows and `550` on macOS, both
narrower than most viewports, which leaves the page stranded partway across the
screen. Setting it to the viewport width is
the one value where 1:1 tracking and a complete traverse are simultaneously
true, and `swipeAnim.fullTraverse` keeps it there as the window resizes. A side
effect is that the commit threshold — a hardcoded 25% in `SwipeTracker.cpp` —
becomes 25% of the window width rather than a fixed distance.

Mozilla's smaller macOS default is worth knowing about but does not mean macOS
wants a different value from this project: `pixel-size` is not a sensitivity
knob. Because the delta is clamped to `[-1, 1]` and the page moves by
`delta × pixel-size`, that preference is simultaneously the scale factor *and*
the furthest the page can ever travel. Anything below the viewport width strands
the page partway across the screen no matter how far the gesture goes. The
viewport width is the only value that satisfies both, on all three platforms.

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

If nothing happens at all — no animation, and `SwipeAnim` undefined in the
Browser Console — the payload never loaded, and the console is the only place
that says so. The loader reports its failures as `[swipe-anim]` lines and is
otherwise silent, because a browser that started normally without the payload
looks exactly like one that never had it installed. The likeliest cause is an
installation predating the `resource:` loader now running on Firefox 155; see
[Requirements](#requirements). Re-running the install line fixes it.

Two helpers are available in the Browser Console (`Ctrl+Shift+J`):

```js
SwipeAnim.health(window)   // stuck state, leftover nodes, swallowed errors, recent gestures
SwipeAnim.reset(window)    // clear state and remove leftovers, keeping the snapshot cache
```

`health()` reports whether the overrides are still installed, any exceptions
that were caught and swallowed, snapshot capture failures, and a log of recent
gestures including which directions had a cached snapshot.

If a destination page has no usable snapshot — never visited this session,
evicted from the cache, known to be out of date, or holding a URL that does not
match the history entry — that gesture falls back to Firefox's own arrow
indicator rather than showing a blank or misleading card. `gestureLog` records
which of those it was under `reason`.

`health().cached` and `stats().cacheEntries` list the cache one row per tab,
with the tab's current title, so a snapshot can be tied back to the tab it
belongs to.

Two counters are worth watching if back-swipes fall back to the arrows more
often than you would like:

```js
SwipeAnim.stats(window).staleMarks   // refreshes that lost their race
SwipeAnim.stats(window).staleSkips   // gestures that cost you
```

`staleMarks` climbing during ordinary browsing means the pre-navigation refresh
is routinely losing to the navigation, which is a limitation of doing the
capture over IPC rather than anything misconfigured. Setting
`swipeAnim.staleFallback` to `false` trades the arrow fallback back for an
animation that may show the wrong scroll position.

## Known limitations

- The macOS support has been verified on one machine — Firefox 152.0.6 on a
  MacBook Pro (M2, macOS 26) with the built-in trackpad, at 2× display scaling.
  What was checked there specifically: the gesture arrives with continuous
  deltas as it does on GTK; the page tracks the fingers 1:1 and traverses the
  full window; reversing mid-gesture stays positional rather than jumping; and
  install, uninstall and re-install leave the app bundle exactly as they found
  it. An external display, a Magic Mouse and macOS versions before 26 have not
  been exercised.
- A conventional wheel mouse never produces a swipe on macOS: its scroll becomes
  a `ScrollWheelInput` rather than a `PanGestureInput`, so it never reaches
  `SwipeTracker`. A Magic Mouse does, gated by its own *Mouse → More Gestures*
  setting; that path is untested here.
- The Windows support is newer than the Linux support and has been verified on
  one machine — Firefox 152 ARM64 on Windows 11, at 1.25× display scaling, with
  a Precision Touchpad. What was checked there specifically: the gesture stream
  arrives with continuous deltas as it does on GTK; Direct Manipulation's
  post-release inertia does not disturb the settle animation; fractional display
  scaling neither blurs nor misaligns a snapshot; and reversing mid-gesture
  stays positional rather than jumping. Other hardware, a second display at a
  different scale, and touchscreen panning have not been exercised.
- The snapshot cache holds four entries per tab, evicting whichever is furthest
  from the current position, and twenty-four across the window, evicting from
  the least recently used tab first. Swiping to a page beyond that falls back to
  the arrows.
- Only the selected tab is snapshotted, so a tab that navigates in the
  background has nothing cached for the pages it passed through. Switching to it
  captures where it now is, not where it has been.
- A snapshot taken at a different window size is anchored top-left and cropped
  rather than stretched, so a resized window may show a filled strip along an
  edge. The fill colour is sampled from the snapshot to blend in.
- Snapshots are static images. Video, animation and any content that changed
  since capture will not be live during the gesture.
- Because the installed files are not owned by your package manager, they
  survive Firefox upgrades. Uninstall before a major version change, or re-check
  afterwards.
