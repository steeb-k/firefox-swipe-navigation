// 1:1 swipe navigation animation for Firefox (Linux/GTK), pure chrome JS.
// Loaded into a browser window scope via Services.scriptloader.loadSubScript.
// Entry point: SwipeAnim.install(window) / SwipeAnim.uninstall(window)
//
// Visual model (matches WebKit/Safari, not a filmstrip):
//   back    = UNCOVER: previous page is stationary underneath; current page
//             slides off it.
//   forward = COVER:   next page slides in on top of a stationary current page.
// Hence two containers: an underlay that paints below the <browser> and an
// overlay that paints above it.

var SwipeAnim = {
  MAX_CACHE: 6,

  // Tunables. Read live from prefs so they can be changed in about:config
  // without editing this file.
  //   swipeAnim.parallax  0 = incoming page fully stationary (WebKit-like)
  //                       1 = both pages locked together (old filmstrip look)
  //   swipeAnim.dim       peak dim opacity applied to the underneath page
  //   swipeAnim.shadow    drop shadow on the moving page's leading edge
  _prefs(win) {
    const f = (name, dflt) => {
      try {
        return Services.prefs.getFloatPref(name);
      } catch (e) {
        return dflt;
      }
    };
    const b = (name, dflt) => {
      try {
        return Services.prefs.getBoolPref(name);
      } catch (e) {
        return dflt;
      }
    };
    return {
      parallax: Math.max(0, Math.min(1, f("swipeAnim.parallax", 0))),
      dim: Math.max(0, Math.min(1, f("swipeAnim.dim", 0.28))),
      shadow: b("swipeAnim.shadow", true),
      fullTraverse: b("swipeAnim.fullTraverse", true),
      positionalCommit: b("swipeAnim.positionalCommit", true),
      staleFallback: b("swipeAnim.staleFallback", true),
      pixelSize: f("widget.swipe.pixel-size", 1100),
    };
  },

  // SwipeTracker::ProcessEvent pins the REPORTED delta to 0.999 * 0.25 whenever
  // ComputeSwipeSuccess() is false but the gesture is already past the 0.25
  // threshold, so the UI does not falsely promise navigation. Reversing
  // direction trips the velocity check at the top of ComputeSwipeSuccess:
  //
  //   if (mCurrentVelocity * targetValue < -velocity_twitch_tolerance())
  //     return false;
  //
  // ...and twitch-tolerance defaults to 0.0000001, so ANY reverse motion trips
  // it. The result is an instant jump to 25% of the viewport with no animation.
  // Note success-velocity-contribution does NOT help: that early return fires
  // before the contribution is ever used.
  //
  // Making the tolerance effectively infinite removes the early return, and with
  // contribution at 0 ComputeSwipeSuccess reduces to the purely positional
  // |mGestureAmount| >= 0.25 -- which can never disagree with the pinning
  // condition, so the pin becomes unreachable. Commit/cancel is then decided by
  // where you let go, not by which way you were moving.
  _syncTrackerPrefs(state) {
    const win = state.win;
    const cfg = this._prefs(win);
    const setFloat = (name, value) => {
      let have = NaN;
      try {
        have = Services.prefs.getFloatPref(name);
      } catch (e) {}
      if (!(Math.abs(have - value) < 1e-6)) {
        // Float prefs are stored as strings in Gecko.
        Services.prefs.setCharPref(name, String(value));
      }
    };

    if (cfg.positionalCommit) {
      setFloat("widget.swipe.velocity-twitch-tolerance", 1e12);
      setFloat("widget.swipe.success-velocity-contribution", 0);
    }

    if (!cfg.fullTraverse) {
      return null;
    }
    const browser = win.gBrowser?.selectedBrowser;
    const width = browser?.getBoundingClientRect().width;
    if (!width) {
      return null;
    }
    setFloat("widget.swipe.pixel-size", Math.round(width));
    return Math.round(width);
  },

  // widget.swipe.pixel-size is the denominator SwipeTracker.cpp divides finger
  // travel by, and mGestureAmount is clamped to [-1, 1] by ClampToAllowedRange.
  // So the page can never travel further than pixel-size CSS px. Its default
  // (1100 on Linux) is narrower than most viewports, which strands the page
  // partway across. Setting it to the viewport width is the single value where
  // 1:1 tracking and a complete traverse are both true.
  _syncPixelSize(state) {
    return this._syncTrackerPrefs(state);
  },

  install(win) {
    this.uninstall(win);

    const state = {
      win,
      cache: new Map(), // sh-index -> {bitmap, w, h, url}
      underlay: null,
      overlay: null,
      incomings: { back: null, fwd: null },
      gesture: null,
      frames: [],
      listener: null,
      origFns: {},
    };
    win.__swipeAnimState = state;

    const anim = win.gHistorySwipeAnimation;
    if (!anim) {
      throw new Error("gHistorySwipeAnimation missing");
    }

    for (const fn of [
      "startAnimation",
      "updateAnimation",
      "stopAnimation",
      "swipeEndEventReceived",
    ]) {
      state.origFns[fn] = anim[fn];
    }

    const self = this;
    const guard = (name, impl) =>
      function () {
        try {
          return impl.apply(self, [state, ...arguments]);
        } catch (e) {
          // Record as well as log: a swallowed exception here presents as
          // "the page just doesn't move", with nothing obvious in the console.
          state.errors = state.errors || [];
          state.errors.unshift({
            at: new Date().toTimeString().slice(0, 8),
            where: name,
            error: `${e.name}: ${e.message}`,
            line: String(e.stack || "").split("\n")[0].split(":").slice(-2).join(":"),
          });
          state.errors.length = Math.min(state.errors.length, 10);
          win.console.error("[swipe-anim] " + name, e);
        }
      };

    anim.startAnimation = guard("start", self._onStart);
    anim.updateAnimation = guard("update", self._onUpdate);
    anim.stopAnimation = guard("stop", self._onStop);
    anim.swipeEndEventReceived = guard("end", self._onStop);

    // Snapshots are taken while we are sitting stably ON an entry, so the entry
    // we are about to leave has always already been captured under its own key.
    state.lastIdx = this._shIndex(win.gBrowser.selectedBrowser);
    state.settleTimer = null;

    const scheduleSettleCapture = browser => {
      if (state.settleTimer) {
        win.clearTimeout(state.settleTimer);
      }
      state.settleTimer = win.setTimeout(() => {
        state.settleTimer = null;
        if (browser !== win.gBrowser.selectedBrowser) {
          return;
        }
        const idx = self._shIndex(browser);
        state.lastIdx = idx;
        self._capture(state, browser, idx).catch(() => {});
      }, 350);
    };

    state.listener = {
      onStateChange(browser, webProgress, request, flags) {
        const WPL = Ci.nsIWebProgressListener;
        if (!webProgress.isTopLevel || !(flags & WPL.STATE_IS_WINDOW)) {
          return;
        }
        if (browser !== win.gBrowser.selectedBrowser) {
          return;
        }
        if (flags & WPL.STATE_START) {
          // Refresh the page we are leaving, keyed by where we actually were.
          self._capture(state, browser, state.lastIdx).catch(() => {});
        } else if (flags & WPL.STATE_STOP) {
          scheduleSettleCapture(browser);
        }
      },
      // Fires for bfcache restores and same-document navigations too, where
      // STATE_STOP may never arrive.
      onLocationChange(browser, webProgress, request, uri, flags) {
        if (!webProgress?.isTopLevel) {
          return;
        }
        if (browser !== win.gBrowser.selectedBrowser) {
          return;
        }
        state.lastIdx = self._shIndex(browser);
        scheduleSettleCapture(browser);
      },
    };
    win.gBrowser.addTabsProgressListener(state.listener);
    self._capture(state, win.gBrowser.selectedBrowser, state.lastIdx).catch(
      () => {}
    );

    // Changing page zoom re-lays-out the content but fires no navigation, so the
    // cached snapshot would keep the old zoom until the next navigation.
    state.onZoom = () => {
      try {
        scheduleSettleCapture(win.gBrowser.selectedBrowser);
      } catch (e) {}
    };
    win.addEventListener("FullZoomChange", state.onZoom, true);
    win.addEventListener("TextZoomChange", state.onZoom, true);

    // Keep pixel-size matched to the viewport so a gesture can always complete.
    state.onResize = () => {
      try {
        self._syncPixelSize(state);
      } catch (e) {}
    };
    win.addEventListener("resize", state.onResize);
    self._syncPixelSize(state);

    return "installed";
  },

  uninstall(win) {
    const state = win.__swipeAnimState;
    if (!state) {
      return "not-installed";
    }
    const anim = win.gHistorySwipeAnimation;
    if (anim) {
      for (const [fn, orig] of Object.entries(state.origFns)) {
        anim[fn] = orig;
      }
    }
    if (state.listener) {
      try {
        win.gBrowser.removeTabsProgressListener(state.listener);
      } catch (e) {}
    }
    if (state.onResize) {
      try {
        win.removeEventListener("resize", state.onResize);
      } catch (e) {}
    }
    if (state.onZoom) {
      try {
        win.removeEventListener("FullZoomChange", state.onZoom, true);
        win.removeEventListener("TextZoomChange", state.onZoom, true);
      } catch (e) {}
    }
    if (state.settleTimer) {
      try {
        win.clearTimeout(state.settleTimer);
      } catch (e) {}
    }
    for (const p of [
      "widget.swipe.pixel-size",
      "widget.swipe.velocity-twitch-tolerance",
      "widget.swipe.success-velocity-contribution",
    ]) {
      try {
        Services.prefs.clearUserPref(p);
      } catch (e) {}
    }
    this._teardown(state);
    for (const entry of state.cache.values()) {
      try {
        entry.bitmap.close();
      } catch (e) {}
    }
    state.cache.clear();
    delete win.__swipeAnimState;
    return "uninstalled";
  },

  _shIndex(browser) {
    try {
      return browser.browsingContext.sessionHistory.index;
    } catch (e) {
      return -1;
    }
  },

  // idxOverride matters: sessionHistory.index moves BEFORE onStateChange fires
  // for back/forward navigations, and this function awaits, so re-reading the
  // index after the await would file the outgoing page's pixels under the
  // incoming entry's key. Callers pass the index they mean.
  async _capture(state, browser, idxOverride) {
    const win = state.win;
    const wgp = browser.browsingContext?.currentWindowGlobal;
    if (!wgp) {
      return;
    }
    const idx =
      typeof idxOverride === "number" ? idxOverride : this._shIndex(browser);
    if (idx < 0) {
      return;
    }
    const r = browser.getBoundingClientRect();
    if (!r.width || !r.height) {
      return;
    }
    const url = browser.currentURI?.spec;
    const t0 = win.performance.now();

    // The rect MUST be null. drawSnapshot's rect is in DOCUMENT coordinates,
    // not viewport coordinates -- "the area of the document to render, relative
    // to the page" (ext-tabs-base.js). So DOMRect(0, 0, w, h) does not mean
    // "what the user is looking at", it means "the top of the document", and a
    // page scrolled halfway down still snapshots as its own header. Passing null
    // is the documented way to ask for the currently visible viewport, and it is
    // scroll-aware without the parent process needing to know the scroll offset
    // at all.
    //
    // Scale still has to carry zoom. Page zoom scales the content's CSS pixels
    // relative to the browser element's chrome CSS size, so at 130% the viewport
    // is only width/1.3 content px across; multiplying the scale by zoom keeps
    // the bitmap at the same device-pixel size either way, exactly as
    // ext-tabs-base.js does (`drawSnapshot(rect, scale * zoom)`).
    //
    // The fourth argument is resetScrollPosition, and it must stay false: true
    // would reinstate precisely the bug described above.
    const zoom = browser.fullZoom || 1;
    let bmp;
    try {
      bmp = await wgp.drawSnapshot(
        null,
        win.devicePixelRatio * zoom,
        "white",
        false
      );
    } catch (e) {
      // drawSnapshot rejects (often NS_ERROR_LOSS_OF_SIGNIFICANT_DATA) when the
      // content process has not flushed layout, and -- the common case -- when a
      // navigation has already torn down the WindowGlobal we asked. That second
      // case is why an entry can be wrong rather than merely absent: we tried to
      // refresh the page we were leaving, lost the race, and the entry still
      // holds whatever the page looked like at its LAST successful capture,
      // typically load time at scroll 0.
      //
      // So a failure here is not just a missed opportunity, it is positive
      // evidence that any entry we already hold for this index is out of date.
      // Mark it rather than pretending it is good: _buildIncoming refuses to
      // animate to a marked entry and hands the gesture to the stock arrows.
      const stalePrev = state.cache.get(idx);
      if (stalePrev) {
        stalePrev.stale = true;
        state.staleMarks = (state.staleMarks || 0) + 1;
      }
      state.captureFails = (state.captureFails || 0) + 1;
      state.lastCaptureFail = {
        idx,
        url,
        error: String(e && (e.name || e.message || e)),
        markedStale: !!stalePrev,
        at: new Date().toTimeString().slice(0, 8),
      };
      return;
    }
    const prev = state.cache.get(idx);
    if (prev) {
      try {
        prev.bitmap.close();
      } catch (e) {}
    }
    state.cache.set(idx, {
      bitmap: bmp,
      w: bmp.width,
      h: bmp.height,
      cssW: r.width,
      cssH: r.height,
      zoom,
      url,
      ms: +(win.performance.now() - t0).toFixed(1),
    });
    if (state.cache.size > this.MAX_CACHE) {
      const cur = idx;
      const keys = [...state.cache.keys()].sort(
        (a, b) => Math.abs(b - cur) - Math.abs(a - cur)
      );
      while (state.cache.size > this.MAX_CACHE) {
        const k = keys.shift();
        const e = state.cache.get(k);
        try {
          e.bitmap.close();
        } catch (err) {}
        state.cache.delete(k);
      }
    }
  },

  _onStart(state) {
    const win = state.win;
    const anim = win.gHistorySwipeAnimation;
    const browser = win.gBrowser.selectedBrowser;

    // Clear stuck flags FIRST, unconditionally. If these are left set by an
    // aborted gesture, every subsequent swipe silently does nothing.
    state.committing = false;
    state.delegating = false;

    const stack = win.gBrowser.getPanel().querySelector(".browserStack");
    if (!stack) {
      this._teardown(state);
      return;
    }

    this._teardown(state);
    this._syncPixelSize(state);

    const rect = browser.getBoundingClientRect();
    state.gesture = {
      idx: this._shIndex(browser),
      width: rect.width,
      height: rect.height,
      isLTR: anim.isLTR,
      canGoBack: browser.canGoBack,
      canGoForward: browser.canGoForward,
      cfg: this._prefs(win),
    };
    state.frames = [];

    // Refresh the page we are standing on, NOW, while it is still on screen and
    // nothing is navigating. This is the only capture that cannot lose a race,
    // and it is the image _runCommitAnimation slides off on release -- without
    // it the outgoing page visibly snaps to whatever scroll offset it had when
    // it was last captured (usually the top, at load) the instant you let go.
    // It also means a swipe leaves a correctly-scrolled entry behind, so
    // swiping straight back the other way lands on the right position too.
    // Fired before the cards are built so the content-process round trip
    // overlaps the DOM work below; it lands long before release needs it.
    this._capture(state, browser, state.gesture.idx).catch(() => {});

    stack.style.background = "#1c1b22";
    stack.style.overflow = "hidden";
    browser.style.willChange = "transform";

    const mk = () => {
      const el = win.document.createXULElement("box");
      el.style.cssText =
        "position:absolute; inset:0; overflow:hidden; pointer-events:none;";
      return el;
    };
    // First child paints below the <browser>; last child paints above it.
    state.underlay = mk();
    state.underlay.id = "swipeAnimUnderlay";
    stack.insertBefore(state.underlay, stack.firstChild);
    state.overlay = mk();
    state.overlay.id = "swipeAnimOverlay";
    stack.appendChild(state.overlay);

    state.incomings = { back: null, fwd: null };
    if (state.gesture.canGoBack) {
      this._buildIncoming(state, true);
    }
    if (state.gesture.canGoForward) {
      this._buildIncoming(state, false);
    }

    state.gestureLog = state.gestureLog || [];
    state.gestureLog.unshift({
      at: new Date().toTimeString().slice(0, 8),
      outcome: "started",
      currentIdx: state.gesture.idx,
      canGoBack: state.gesture.canGoBack,
      canGoForward: state.gesture.canGoForward,
      backHasSnapshot: !!state.incomings.back?.hasSnapshot,
      fwdHasSnapshot: !!state.incomings.fwd?.hasSnapshot,
      backStale: !!state.incomings.back?.stale,
      fwdStale: !!state.incomings.fwd?.stale,
      cachedKeys: [...state.cache.keys()].sort((a, b) => a - b),
      // Entries we know are out of date: a refresh was attempted and lost the
      // race with the navigation. Swiping to one of these takes the arrows.
      staleKeys: [...state.cache.entries()]
        .filter(([, v]) => v.stale)
        .map(([k]) => k),
      viewportWidth: Math.round(state.gesture.width),
      // A cached bitmap taken at a different window size is a stale snapshot.
      staleSizes: [...state.cache.entries()]
        .filter(([, v]) => Math.abs((v.cssW || 0) - state.gesture.width) > 2)
        .map(([k, v]) => ({ idx: k, capturedAtWidth: Math.round(v.cssW || 0) })),
    });
    state.gestureLog.length = Math.min(state.gestureLog.length, 10);
  },

  // Built eagerly at gesture start: drawImage of a full-viewport bitmap plus a
  // DOM insertion costs a frame, and doing it lazily on the first update drops
  // that frame right as the finger starts moving.
  // Draws the snapshot at the scale it was CAPTURED at, anchored top-left, inside
  // an opaque card that fills the current viewport. Scaling the bitmap to the
  // current viewport instead distorts the page after a window resize. Anchoring
  // shows fill on a wider/taller window and crops on a smaller one, which reads
  // as "the page as it was" rather than a squashed copy. The fill colour is
  // sampled from the snapshot so any uncovered strip blends in -- the same idea
  // as WebKit's backgroundColorForCurrentSnapshot.
  _makeCard(state, entry) {
    const win = state.win;
    const g = state.gesture;
    let fill = "#1c1b22";
    let canvas = null;

    if (entry) {
      canvas = win.document.createElementNS(
        "http://www.w3.org/1999/xhtml",
        "canvas"
      );
      canvas.width = entry.w;
      canvas.height = entry.h;
      const ctx = canvas.getContext("2d", { alpha: false });
      ctx.drawImage(entry.bitmap, 0, 0);
      const cw = entry.cssW || g.width;
      const ch = entry.cssH || g.height;
      canvas.style.cssText =
        `position:absolute; top:0; left:0; width:${cw}px; height:${ch}px;`;
      try {
        const d = ctx.getImageData(
          Math.max(0, entry.w - 2),
          Math.max(0, entry.h - 2),
          1,
          1
        ).data;
        fill = `rgb(${d[0]},${d[1]},${d[2]})`;
      } catch (e) {}
    }

    const card = win.document.createXULElement("box");
    card.style.cssText =
      `position:absolute; top:0; left:0; width:${g.width}px; ` +
      `height:${g.height}px; overflow:hidden; background:${fill}; ` +
      `will-change:transform; visibility:hidden;`;
    if (canvas) {
      card.appendChild(canvas);
    }
    return { card, canvas, fill };
  },

  // Built eagerly at gesture start: drawImage of a full-viewport bitmap plus a
  // DOM insertion costs a frame, and doing it lazily on the first update drops
  // that frame right as the finger starts moving.
  _buildIncoming(state, goingBack) {
    const win = state.win;
    const g = state.gesture;
    const target = goingBack ? g.idx - 1 : g.idx + 1;
    const entry = state.cache.get(target);
    // An entry _capture marked stale is a picture of the right page at the
    // wrong moment -- animating to it promises a destination that is not what
    // will actually appear. Treat it as no snapshot at all so the gesture falls
    // back to the arrows, the same as a page we have never seen.
    const stale = !!entry?.stale && g.cfg.staleFallback;
    const usable = !!entry && !stale;
    // back uncovers (incoming below), forward covers (incoming above)
    const container = goingBack ? state.underlay : state.overlay;

    const { card } = this._makeCard(state, usable ? entry : null);

    // Dim sits over whichever page is underneath, and lifts as it takes over.
    const dim = win.document.createXULElement("box");
    dim.style.cssText =
      "position:absolute; inset:0; background:#000; opacity:0; " +
      "visibility:hidden; pointer-events:none;";

    if (goingBack) {
      // underlay: card is the underneath page, dim goes on top of it
      container.appendChild(card);
      container.appendChild(dim);
    } else {
      // overlay: dim goes under the incoming card so it dims the live browser
      container.appendChild(dim);
      container.appendChild(card);
    }

    const rec = { card, dim, goingBack, hasSnapshot: usable, target, stale };
    state.incomings[goingBack ? "back" : "fwd"] = rec;
    return rec;
  },

  _onUpdate(state, aVal) {
    const win = state.win;
    // Once we have handed a gesture to the stock arrow UI, stay out of the way.
    if (state.delegating) {
      try {
        state.origFns.updateAnimation.call(win.gHistorySwipeAnimation, aVal);
      } catch (e) {}
      return;
    }
    const g = state.gesture;
    if (!g || !state.underlay) {
      return;
    }
    if (state.committing) {
      return; // commit animation owns the transforms now
    }
    state.frames.push(win.performance.now());
    g.lastVal = aVal;

    // Diagnostic: SwipeTracker pins the reported delta to exactly
    // 0.999 * kSwipeSuccessThreshold (0.24975) when it wants to suppress the
    // commit state. Seeing this means the velocity abort is still firing and the
    // page will visibly snap. Should stay 0 with positionalCommit enabled.
    if (Math.abs(Math.abs(aVal) - 0.999 * 0.25) < 1e-5) {
      state.pinnedDeltaSeen = (state.pinnedDeltaSeen || 0) + 1;
      state.lastPinnedAt = new Date().toTimeString().slice(0, 8);
    }

    const browser = win.gBrowser.selectedBrowser;
    const ltr = g.isLTR;
    const goingBack = ((aVal > 0 && ltr) || (aVal < 0 && !ltr)) && g.canGoBack;
    const goingFwd = ((aVal > 0 && !ltr) || (aVal < 0 && ltr)) && g.canGoForward;

    const hideAll = () => {
      for (const rec of [state.incomings.back, state.incomings.fwd]) {
        if (rec) {
          rec.card.style.visibility = "hidden";
          rec.dim.style.visibility = "hidden";
        }
      }
    };

    if (!goingBack && !goingFwd) {
      // Swiping toward an entry that does not exist: nothing may move, and
      // releasing here must NOT run a commit animation.
      g.lastCommitDir = null;
      browser.style.translate = "0px";
      browser.style.boxShadow = "";
      hideAll();
      return;
    }
    g.lastCommitDir = goingBack ? "back" : "fwd";

    // True 1:1: |aVal| * pixelSize is the finger's CSS-pixel travel.
    let dx = aVal * g.cfg.pixelSize;
    if (Math.abs(dx) > g.width) {
      dx = Math.sign(dx) * g.width;
    }
    const t = Math.min(Math.abs(dx) / g.width, 1); // 0..1 progress
    // Which edge the incoming page comes from: content moving right (dx>0)
    // reveals the left edge.
    const edge = dx > 0 ? -1 : 1;
    const off = edge * g.width * (1 - t);

    const inc =
      state.incomings[goingBack ? "back" : "fwd"] ||
      this._buildIncoming(state, goingBack);

    // No usable snapshot for the destination: showing a flat grey card, or one
    // we know is out of date, is worse than admitting we cannot do it. Hand
    // this gesture to the stock arrow UI.
    if (!inc.hasSnapshot) {
      this._beginDelegate(
        state,
        aVal,
        goingBack,
        inc.target,
        inc.stale ? "stale-snapshot" : "no-snapshot"
      );
      return;
    }

    const other = state.incomings[goingBack ? "fwd" : "back"];
    if (other) {
      other.card.style.visibility = "hidden";
      other.dim.style.visibility = "hidden";
    }
    inc.card.style.visibility = "visible";
    inc.dim.style.visibility = "visible";

    const shadow = g.cfg.shadow
      ? `${edge * 10}px 0 26px rgba(0,0,0,0.55)`
      : "";

    if (goingBack) {
      // UNCOVER: previous page stationary underneath, current page slides off.
      browser.style.translate = `${dx.toFixed(2)}px 0px`;
      browser.style.boxShadow = shadow;
      inc.card.style.translate = `${(off * g.cfg.parallax).toFixed(2)}px 0px`;
      inc.dim.style.translate = inc.card.style.translate;
      inc.dim.style.opacity = ((1 - t) * g.cfg.dim).toFixed(3);
    } else {
      // COVER: next page slides in on top of a stationary current page.
      browser.style.translate = `${(dx * g.cfg.parallax).toFixed(2)}px 0px`;
      browser.style.boxShadow = "";
      inc.card.style.translate = `${off.toFixed(2)}px 0px`;
      inc.card.style.boxShadow = shadow;
      inc.dim.style.translate = "0px";
      inc.dim.style.opacity = (t * g.cfg.dim).toFixed(3);
    }
  },

  // Fall back to Firefox's own arrow indicator for this gesture.
  _beginDelegate(state, aVal, goingBack, targetIdx, reason) {
    const win = state.win;
    const anim = win.gHistorySwipeAnimation;
    const g = state.gesture;

    if (reason === "stale-snapshot") {
      state.staleSkips = (state.staleSkips || 0) + 1;
    }
    state.gestureLog = state.gestureLog || [];
    state.gestureLog.unshift({
      at: new Date().toTimeString().slice(0, 8),
      outcome: "delegated-to-arrows",
      reason: reason || "no-snapshot",
      dir: goingBack ? "back" : "fwd",
      targetIdx,
      currentIdx: g ? g.idx : null,
      cachedKeys: [...state.cache.keys()].sort((a, b) => a - b),
      viewportWidth: g ? Math.round(g.width) : null,
    });
    state.gestureLog.length = Math.min(state.gestureLog.length, 10);

    this._teardown(state);
    state.delegating = true;
    try {
      state.origFns.startAnimation.call(anim);
      state.origFns.updateAnimation.call(anim, aVal);
    } catch (e) {
      win.console.error("[swipe-anim] delegate", e);
    }
  },

  _onStop(state) {
    const win = state.win;
    const g = state.gesture;
    if (state.delegating) {
      state.delegating = false;
      try {
        state.origFns.stopAnimation.call(win.gHistorySwipeAnimation);
      } catch (e) {}
      return;
    }
    if (state.committing) {
      return; // stopAnimation and swipeEndEventReceived both land here
    }
    const browser = win.gBrowser?.selectedBrowser;

    // Cancel path already animated itself: SwipeTracker::ProcessEvent calls
    // StartAnimating(eventAmount, 0.0) and springs back to 0 while emitting
    // updates, so by now the page is home. Commit path gets no spring at all --
    // eSwipeGesture fires immediately -- so it needs one from us.
    const committing =
      g && g.lastCommitDir && Math.abs(g.lastVal || 0) >= 0.25;
    if (!committing) {
      this._teardown(state);
      if (browser) {
        this._capture(state, browser, this._shIndex(browser)).catch(() => {});
      }
      return;
    }

    try {
      this._runCommitAnimation(state);
    } catch (e) {
      // Must clear `committing` here: _onUpdate early-returns while it is set,
      // so leaving it true silently disables every future gesture.
      win.console.error("[swipe-anim] commit", e);
      state.committing = false;
      this._teardown(state);
    }
  },

  // The live <browser> is already navigating, so continuing to slide IT would
  // show its content change from the old page to the new one mid-flight. Instead
  // hand the whole commit phase to snapshots layered above a stationary browser:
  //   overlay = [ destination snapshot at 0 ] [ outgoing snapshot sliding off ]
  // then drop the overlay once the live page has painted. This also removes the
  // white flash that used to happen between teardown and first paint.
  _runCommitAnimation(state) {
    const win = state.win;
    const g = state.gesture;
    const browser = win.gBrowser.selectedBrowser;
    const dur = Math.max(
      80,
      Math.min(600, this._prefsNum(win, "swipeAnim.commitMs", 260))
    );

    state.committing = true;

    const goingBack = g.lastCommitDir === "back";
    const inc = state.incomings[g.lastCommitDir];
    let dx = g.lastVal * g.cfg.pixelSize;
    if (Math.abs(dx) > g.width) {
      dx = Math.sign(dx) * g.width;
    }
    const edge = dx > 0 ? -1 : 1;

    // Destination snapshot must sit ABOVE the browser now, because the browser
    // still shows the outgoing page until navigation paints.
    if (inc) {
      inc.dim.style.opacity = 0;
      inc.dim.style.visibility = "hidden";
      state.overlay.appendChild(inc.card);
      inc.card.style.translate = "0px";
      inc.card.style.visibility = "visible";
      inc.card.style.boxShadow = "";
    }

    // Outgoing page: a snapshot of where we are leaving from, so it keeps
    // showing the OLD content while it slides away.
    const outEntry = state.cache.get(g.idx);
    let outCanvas = null;
    if (outEntry) {
      const made = this._makeCard(state, outEntry);
      outCanvas = made.card;
      outCanvas.style.visibility = "visible";
      state.overlay.appendChild(outCanvas);
      state.commitOutCanvas = outCanvas;
    }

    // Browser goes home immediately; it is fully covered by the overlay.
    browser.style.translate = "0px";
    browser.style.boxShadow = "";

    const startDx = dx;
    const endDx = -edge * g.width; // finish travelling the way it was going
    const target = outCanvas || browser;
    const shadowOn = g.cfg.shadow;
    let startTime = null;

    const step = now => {
      if (!state.committing) {
        return;
      }
      if (startTime === null) {
        startTime = now;
      }
      const p = Math.min((now - startTime) / dur, 1);
      const e = 1 - Math.pow(1 - p, 3); // ease-out cubic
      const cur = startDx + (endDx - startDx) * e;
      target.style.translate = `${cur.toFixed(2)}px 0px`;
      if (shadowOn && target === outCanvas) {
        target.style.boxShadow = `${edge * 10}px 0 26px rgba(0,0,0,${(
          0.55 *
          (1 - e)
        ).toFixed(3)})`;
      }
      if (p < 1) {
        win.requestAnimationFrame(step);
      } else {
        if (outCanvas) {
          outCanvas.remove();
          state.commitOutCanvas = null;
        }
        this._finishCommit(state);
      }
    };
    win.requestAnimationFrame(step);
  },

  // Hold the destination snapshot until the live page has actually painted,
  // rather than guessing with a fixed delay.
  _finishCommit(state) {
    const win = state.win;
    const browser = win.gBrowser?.selectedBrowser;
    const done = () => {
      if (!state.committing) {
        return;
      }
      state.committing = false;
      this._teardown(state);
      if (browser) {
        this._capture(state, browser, this._shIndex(browser)).catch(() => {});
      }
    };

    if (!browser) {
      done();
      return;
    }

    let settled = false;
    // viaPaint: we saw the new content paint, so spend two frames letting it
    // composite before dropping the snapshot. On the timeout path we must NOT
    // wait for rAF -- it is throttled hard in occluded/background windows, which
    // would leave a stale snapshot pinned over the live page for seconds.
    const finish = viaPaint => {
      if (settled) {
        return;
      }
      settled = true;
      win.clearTimeout(bail);
      browser.removeEventListener("MozAfterPaint", onPaint, true);
      if (viaPaint) {
        win.requestAnimationFrame(() => win.requestAnimationFrame(done));
        // Even here, do not trust rAF indefinitely.
        win.setTimeout(done, 250);
      } else {
        done();
      }
    };
    const onPaint = () => finish(true);
    // Backstop: never leave a stale snapshot pinned over the page.
    const bail = win.setTimeout(() => finish(false), 600);
    browser.addEventListener("MozAfterPaint", onPaint, true);
  },

  // Manual unstick: clears flags, removes leftover nodes, restores the browser
  // and the .browserStack styles, without dropping the snapshot cache.
  reset(win) {
    const state = win.__swipeAnimState;
    if (!state) {
      return { reset: false, reason: "not installed" };
    }
    state.committing = false;
    state.delegating = false;
    this._teardown(state);
    return {
      reset: true,
      cached: [...state.cache.keys()].sort((a, b) => a - b),
    };
  },

  // Snapshot of everything that could wedge a gesture. Read this when swipes
  // stop animating.
  health(win) {
    const state = win.__swipeAnimState;
    if (!state) {
      return { installed: false };
    }
    const anim = win.gHistorySwipeAnimation;
    const browser = win.gBrowser?.selectedBrowser;
    const stack = win.gBrowser?.getPanel()?.querySelector(".browserStack");
    const orig = fn =>
      String(anim?.[fn] || "").includes("HSA_") ? "STOCK" : "ours";
    return {
      installed: true,
      overrides: {
        startAnimation: orig("startAnimation"),
        updateAnimation: orig("updateAnimation"),
        stopAnimation: orig("stopAnimation"),
      },
      stuckFlags: { committing: !!state.committing, delegating: !!state.delegating },
      gestureActive: !!state.gesture,
      leftoverNodes: {
        underlay: win.document.querySelectorAll("#swipeAnimUnderlay").length,
        overlay: win.document.querySelectorAll("#swipeAnimOverlay").length,
        arrows: win.document.querySelectorAll("#historySwipeAnimationContainer")
          .length,
      },
      residualStyles: {
        browserTranslate: browser?.style.translate || "",
        browserWillChange: browser?.style.willChange || "",
        browserShadow: browser?.style.boxShadow ? "set" : "",
        stackBackground: stack?.style.background || "",
        stackOverflow: stack?.style.overflow || "",
      },
      viewport: browser
        ? {
            cssWidth: Math.round(browser.getBoundingClientRect().width),
            cssHeight: Math.round(browser.getBoundingClientRect().height),
          }
        : null,
      historyIdx: browser ? this._shIndex(browser) : null,
      cached: [...state.cache.entries()].map(([k, v]) => ({
        idx: k,
        capturedAtWidth: Math.round(v.cssW || 0),
        stale: !!v.stale,
      })),
      captureFails: state.captureFails || 0,
      lastCaptureFail: state.lastCaptureFail || null,
      // How often a capture failure landed on an entry we already held (so the
      // entry is now known-wrong), and how often that actually cost a gesture.
      // Both high means the pre-navigation capture is losing its race
      // routinely, and only a scroll-driven recapture will fix it properly.
      staleMarks: state.staleMarks || 0,
      staleSkips: state.staleSkips || 0,
      // Swallowed exceptions. Non-empty here is the usual cause of "no animation".
      errors: state.errors || [],
      gestureLog: (state.gestureLog || []).slice(0, 6),
    };
  },

  _prefsNum(win, name, dflt) {
    try {
      return Services.prefs.getIntPref(name);
    } catch (e) {
      return dflt;
    }
  },

  _teardown(state) {
    const win = state.win;
    const browser = win.gBrowser?.selectedBrowser;

    // Sweep by ID as well as by reference. A card orphaned by an aborted gesture
    // (or by a re-install replacing `state`) is unreachable from these refs and
    // would survive as a leftover strip over the page.
    try {
      for (const id of ["swipeAnimUnderlay", "swipeAnimOverlay"]) {
        for (const node of [...win.document.querySelectorAll("#" + id)]) {
          node.remove();
        }
      }
    } catch (e) {}

    // Firefox's own arrow container is torn down on a `transitionend` that does
    // not always arrive, so a delegated gesture can leave it parented in
    // .browserStack. Clear it via its own bookkeeping so refs are nulled too.
    if (!state.delegating) {
      try {
        const anim = win.gHistorySwipeAnimation;
        if (anim && anim._container) {
          anim._isStoppingAnimation = false;
          anim._removeBoxes();
        }
        for (const node of [
          ...win.document.querySelectorAll("#historySwipeAnimationContainer"),
        ]) {
          node.remove();
        }
      } catch (e) {}
    }
    if (browser) {
      browser.style.translate = "";
      browser.style.willChange = "";
      browser.style.boxShadow = "";
    }
    const stack = win.gBrowser?.getPanel()?.querySelector(".browserStack");
    if (stack) {
      stack.style.background = "";
      stack.style.overflow = "";
    }
    if (state.commitOutCanvas) {
      state.commitOutCanvas.remove();
      state.commitOutCanvas = null;
    }
    for (const key of ["back", "fwd"]) {
      const rec = state.incomings?.[key];
      if (rec) {
        rec.card.remove();
        rec.dim.remove();
      }
      if (state.incomings) {
        state.incomings[key] = null;
      }
    }
    for (const key of ["underlay", "overlay"]) {
      if (state[key]) {
        state[key].remove();
        state[key] = null;
      }
    }
    state.gesture = null;
  },

  stats(win) {
    const state = win.__swipeAnimState;
    if (!state) {
      return { installed: false };
    }
    const f = state.frames;
    const gaps = [];
    for (let i = 1; i < f.length; i++) {
      gaps.push(+(f[i] - f[i - 1]).toFixed(2));
    }
    const sorted = [...gaps].sort((a, b) => a - b);
    return {
      installed: true,
      cfg: this._prefs(win),
      cacheEntries: [...state.cache.entries()].map(([k, v]) => ({
        idx: k,
        url: v.url,
        px: `${v.w}x${v.h}`,
        captureMs: v.ms,
        stale: !!v.stale,
      })),
      lastGestureFrames: f.length,
      medianGap: sorted.length ? sorted[Math.floor(sorted.length / 2)] : null,
      maxGap: sorted.length ? sorted[sorted.length - 1] : null,
      gapsOver20ms: gaps.filter(g => g > 20).length,
      // Should remain 0. Non-zero means the reverse-direction snap still fires.
      pinnedDeltaSeen: state.pinnedDeltaSeen || 0,
      lastPinnedAt: state.lastPinnedAt || null,
      // Non-zero here explains a grey fallback page: no snapshot got cached.
      captureFails: state.captureFails || 0,
      lastCaptureFail: state.lastCaptureFail || null,
      staleMarks: state.staleMarks || 0,
      staleSkips: state.staleSkips || 0,
      gestureLog: state.gestureLog || [],
      trackerPrefs: {
        pixelSize: (() => { try { return Services.prefs.getFloatPref("widget.swipe.pixel-size"); } catch (e) { return null; } })(),
        twitchTolerance: (() => { try { return Services.prefs.getFloatPref("widget.swipe.velocity-twitch-tolerance"); } catch (e) { return null; } })(),
        velocityContribution: (() => { try { return Services.prefs.getFloatPref("widget.swipe.success-velocity-contribution"); } catch (e) { return null; } })(),
      },
    };
  },
};
