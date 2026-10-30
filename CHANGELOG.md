# Changelog

## 1.0.0 (2026-10-30)

First public release.

- Floating, pinned 16:9 mpv player for almost any video link, with no login and no browser.
- F-22 Raptor inspired HUD: CRUISE (light) and COMBAT (full) modes with a MASTER ARM panel, live audio signal meter, progress ring, end-of-video ramp with amber and red timers and a NEXT card, PIN mode and a keyboard and mouse help panel.
- LIVE mode for live streams and webcams.
- The first player opens centred; more players park in the free corners, with size, nudge and fullscreen controls.
- Keyboard: 5 and 10 second seeks, 0 to 9 jumps to 0 to 90 %, speed, repeat, link info, and a key card on the first launch.
- Omarchy bar button (bar-widget plugin). The first click opens the installer in a terminal.
- `install.sh` asks before it adds its one line to `hyprland.lua` and backs up every file it replaces. `uninstall.sh` removes only what it installed and checks real paths.
