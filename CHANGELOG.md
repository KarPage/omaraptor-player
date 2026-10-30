# Changelog

## 1.0.2 (2026-10-30)

- ARMED, then FIRE. A copied link (<kbd>Super</kbd>+<kbd>Alt</kbd>+<kbd>Y</kbd> or PASTE LINK) now loads paused in a launch console and waits. Press FIRE (click, <kbd>Enter</kbd> or <kbd>Space</kbd>) for a short countdown, then the picture expands into the HUD. <kbd>Esc</kbd> goes back to the paste screen. A typed link fires by itself.
- Gauge cluster on the launch console: platform badge, title and chips, SIGNAL and BUFFER bars, and MASTER ARM / SEEKER / RELEASE tiles.
- The `+` button opens an empty player on the NO SIGNAL / PASTE LINK screen, at 85 % of the player you clicked and centred over it. It no longer starts the copied link by itself.
- The signal meter keeps showing the real levels while muted, in rust under the MUTED tag.
- YouTube Mix links (`list=RD...`) play the one video at once instead of resolving the endless mix first. Up next still continues with the mix.
- The KEY HINTS switch (`T` in the `?` panel) takes effect at once, with a short flash on the `T` key.
- Hardware decoding now defaults to `hwdec=auto-copy-safe`, which avoids a VA-API crash on Intel (iHD) when a window closes or switches video. To go back, set `hwdec=auto-safe` in `~/.config/omaraptor/mpv.conf`.

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
