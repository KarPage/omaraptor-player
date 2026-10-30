#!/usr/bin/env bash
# OmaRaptor Player installer for Omarchy (Hyprland Lua config). Run it again to update.
#
#   ./install.sh    install or update. It asks before it adds its one line to hyprland.lua,
#                   and never adds it without a terminal to ask in.
#
# Installs ~/.local/bin/omaraptor, ~/.config/omaraptor (your script-opts are kept),
# ~/.config/hypr/omaraptor.lua plus one require line, a .desktop entry and icons.
# Every file it replaces is backed up first. Nothing is downloaded.
# Needs: mpv, yt-dlp, socat, jq, wl-clipboard, hyprctl.
set -euo pipefail
SRC=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
BIN=${XDG_BIN_HOME:-$HOME/.local/bin}; CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}; HYPR=$CFG/hypr
STAMP=$(date +%Y%m%d%H%M%S)
say() { printf '  %s\n' "$*"; }
backup() { if [[ -e $1 ]] && ! cmp -s "$1" "$2"; then cp -p "$1" "$1.bak-omaraptor-$STAMP"; say "backup $1.bak-omaraptor-$STAMP"; fi; }
put() { mkdir -p "$(dirname "$2")"; backup "$2" "$1"; install -m "$3" "$1" "$2"; }

echo "OmaRaptor Player $(cat "$SRC/VERSION"): install"
missing=(); for c in mpv yt-dlp socat jq wl-paste hyprctl; do command -v "$c" >/dev/null || missing+=("$c"); done
((${#missing[@]})) && say "missing: ${missing[*]}  (Omarchy: sudo pacman -S --needed mpv yt-dlp socat jq wl-clipboard)"

put "$SRC/bin/omaraptor" "$BIN/omaraptor" 755
for f in mpv.conf input.conf scripts/omaraptor-hud.lua scripts/omaraptor-autoplay.lua; do
  put "$SRC/config/$f" "$CFG/omaraptor/$f" 644
done
[[ -f $CFG/omaraptor/script-opts/omaraptor-hud.conf ]] ||
  put "$SRC/config/script-opts/omaraptor-hud.conf" "$CFG/omaraptor/script-opts/omaraptor-hud.conf" 644
cp "$SRC/VERSION" "$CFG/omaraptor/.installed-version"

# Hyprland: window rules + key binds live in their own file, loaded by one line.
put "$SRC/hypr/omaraptor.lua" "$HYPR/omaraptor.lua" 644
if [[ -f $HYPR/hyprland.lua ]]; then
  if ! grep -qx 'require("hypr.omaraptor")' "$HYPR/hyprland.lua"; then
    ok=0
    if [[ -t 0 ]]; then
      read -r -p "  Add require(\"hypr.omaraptor\") to $HYPR/hyprland.lua? (a backup is made) [Y/n] " a
      [[ ${a:-y} =~ ^[Yy] ]] && ok=1
    fi
    if ((ok)); then
      cp -p "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak-omaraptor-$STAMP"
      printf '\n-- OmaRaptor Player (remove these two lines to disable)\nrequire("hypr.omaraptor")\n' >> "$HYPR/hyprland.lua"
      say "added require(\"hypr.omaraptor\") to $HYPR/hyprland.lua"
    else
      say "skipped: add require(\"hypr.omaraptor\") to $HYPR/hyprland.lua yourself"
    fi
  fi
else
  say "no $HYPR/hyprland.lua (Lua config) found: load $HYPR/omaraptor.lua yourself"
fi

# App launcher entry + icons
mkdir -p "$DATA/applications"
sed "s#^Exec=omaraptor #Exec=$BIN/omaraptor #" "$SRC/share/applications/omaraptor.desktop" > "$DATA/applications/omaraptor.desktop"
put "$SRC/share/icons/omaraptor.svg" "$DATA/icons/hicolor/scalable/apps/omaraptor.svg" 644
for s in 48 128 256; do put "$SRC/share/icons/omaraptor-$s.png" "$DATA/icons/hicolor/${s}x${s}/apps/omaraptor.png" 644; done
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" 2>/dev/null || true
command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
echo "done. Copy a video link and press SUPER+ALT+Y, or search \"OmaRaptor\" in the app launcher."
