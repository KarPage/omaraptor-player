# Changelog

## 1.0.1 (2026-10-30)

- Key hints are now off by default. The key-letter badges over the buttons no longer show on every hover. Turn them on or off with the KEY HINTS [ON | OFF] switch in the `?` panel (click it, or press `T` while the panel is open). The choice is kept across launches in `$XDG_STATE_HOME/omaraptor/key-hints`.
- LIVE mode in fullscreen keeps the right-hand tape. It has no end and no countdown: it shows how far you are behind the live edge (or your watch time on streams without DVR), with a scrolling watch-time tape and the buffer or watch time at its foot. Click the tape to jump back to the live edge.

## 1.0.0 (2026-10-30)

First public release.

- Floating, pinned 16:9 mpv player for almost any video link, with no login and no browser.
- F-22 Raptor inspired HUD: CRUISE (light) and COMBAT (full) modes with a MASTER ARM panel, live audio signal meter, progress ring, end-of-video ramp with amber and red timers and a NEXT card, PIN mode and a keyboard and mouse help panel.
- LIVE mode for live streams and webcams.
- The first player opens centred; more players park in the free corners, with size, nudge and fullscreen controls.
- Keyboard: 5 and 10 second seeks, 0 to 9 jumps to 0 to 90 %, speed, repeat, link info, and a key card on the first launch.
- Omarchy bar button (bar-widget plugin). The first click opens the installer in a terminal.
- `install.sh` asks before it adds its one line to `hyprland.lua` and backs up every file it replaces. `uninstall.sh` removes only what it installed and checks real paths.
