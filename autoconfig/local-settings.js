// Autoconfig bootstrap for the 1:1 swipe navigation animation.
// Installed to <firefox-install-dir>/defaults/pref/local-settings.js
//
// firefox-swipe-navigation-marker
//
// The marker is what tells the installers this file is one of ours. Without it
// a second install reads its own predecessor as a pre-existing stranger's file,
// backs it up, and restores it on uninstall -- leaving general.config.filename
// pointing at a mozilla.cfg that has just been removed, which Firefox reports
// as a configuration error on the next start.
pref("general.config.filename", "mozilla.cfg");
pref("general.config.obscure_value", 0);
pref("general.config.sandbox_enabled", false);

// NOTE: the widget.swipe.* tuning (pixel-size, velocity-twitch-tolerance,
// success-velocity-contribution) is applied by swipe-anim.js at runtime as USER
// prefs, so SwipeAnim.uninstall() can clear them and fully restore stock
// behaviour. Deliberately not defaulted here -- a default set in this file would
// survive uninstall and leave the browser subtly non-stock.
