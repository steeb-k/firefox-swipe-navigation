// Autoconfig bootstrap for the 1:1 swipe navigation animation.
// Installed to <firefox-install-dir>/defaults/pref/local-settings.js
pref("general.config.filename", "mozilla.cfg");
pref("general.config.obscure_value", 0);
pref("general.config.sandbox_enabled", false);

// NOTE: the widget.swipe.* tuning (pixel-size, velocity-twitch-tolerance,
// success-velocity-contribution) is applied by swipe-anim.js at runtime as USER
// prefs, so SwipeAnim.uninstall() can clear them and fully restore stock
// behaviour. Deliberately not defaulted here -- a default set in this file would
// survive uninstall and leave the browser subtly non-stock.
