#!/usr/bin/env bash
# OmaRaptor Player installer for Omarchy (Hyprland Lua config). Run it again to update.
#
#   bash install.sh    install or update. It asks before it adds its one line to hyprland.lua,
#                      and never adds it without a terminal to ask in.
#                      (./install.sh is the same when the file is marked executable.)
#
# Installs ~/.local/bin/omaraptor, ~/.config/omaraptor (your script-opts are kept),
# ~/.config/hypr/omaraptor.lua plus one require line, a .desktop entry and icons.
# Every file it replaces is copied to <file>.bak-omaraptor-<YYYYMMDDHHMMSS> first.
# Nothing is downloaded. A running player is never killed and never sent "quit".
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
for f in mpv.conf input.conf scripts/omaraptor-autoplay.lua; do
  put "$SRC/config/$f" "$CFG/omaraptor/$f" 644
done
# The HUD is stored as ten ordered parts so the whole script can be published.
# Join them into the one file mpv loads. A running player is not stopped.
hudtmp=$(mktemp)
cat "$SRC/.assemble/hud-src-01" "$SRC/.assemble/hud-src-02" "$SRC/.assemble/hud-src-03" \
  "$SRC/.assemble/hud-src-04" "$SRC/.assemble/hud-src-05" "$SRC/.assemble/hud-src-06" \
  "$SRC/.assemble/hud-src-07" "$SRC/.assemble/hud-src-08" "$SRC/.assemble/hud-src-09" \
  "$SRC/.assemble/hud-src-10" > "$hudtmp"
put "$hudtmp" "$CFG/omaraptor/scripts/omaraptor-hud.lua" 644
rm -f "$hudtmp"
opts=$CFG/omaraptor/script-opts/omaraptor-hud.conf
if [[ ! -f $opts ]]; then
  put "$SRC/config/script-opts/omaraptor-hud.conf" "$opts" 644
elif ! grep -q '^night=' "$opts"; then
  cp -p "$opts" "$opts.bak-omaraptor-$STAMP"
  say "backup $opts.bak-omaraptor-$STAMP"
  printf '\n# NIGHT: off | dim | dimmer. The NIGHT tile and the n key cycle it.\nnight=off\n' >> "$opts"
fi
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

# Reload the HUD in players that already speak this installer's reload handshake.
# Never quit, never signal. A player started from an older HUD has no handshake:
# its picture keeps playing and the new HUD is used the next time it opens.
# input.conf and mpv.conf are read when mpv starts, so a brand-new key waits for that too.
reload_hud() {
  local dir sock resp api n=0 any=0
  if ! command -v socat >/dev/null || ! command -v jq >/dev/null; then
    say "HUD, keys and night level apply the next time a player opens."
    return 0
  fi
  dir=${XDG_RUNTIME_DIR:-/tmp}
  shopt -s nullglob
  for sock in "$dir"/omaraptor-*.sock; do
    [[ -S $sock ]] || continue
    any=1
    resp=$(printf '%s\n' '{"command":["get_property","user-data/omaraptor-hud-api"]}' | socat -t0.4 - "UNIX-CONNECT:$sock" 2>/dev/null || true)
    api=$(printf '%s' "$resp" | jq -r 'select(.error=="success") | .data // empty' 2>/dev/null || true)
    [[ $api == 1 ]] || continue
    printf '%s\n' '{"command":["script-message","omaraptor-hud","standby"]}' | socat -t0.4 - "UNIX-CONNECT:$sock" >/dev/null 2>&1 || true
    sleep 0.2
    jq -n --arg f "$CFG/omaraptor/scripts/omaraptor-hud.lua" '{command:["load-script",$f]}' |
      socat -t1 - "UNIX-CONNECT:$sock" >/dev/null 2>&1 || true
    n=$((n+1))
  done
  if ((n > 0)); then
    say "reloaded the HUD in $n running player(s). They were left playing."
  elif ((any)); then
    say "left running players playing. The new HUD, keys and night level apply the next time they open."
  else
    say "no player is open. The new HUD is used the next time one opens."
  fi
}
reload_hud

echo "done. New windows open unpinned (PIN in the HUD follows you across workspaces)."
echo "Hyprland rules are reloaded. Copy a link and press SUPER+ALT+Y, or search \"OmaRaptor\"."
echo "Replaced files were copied to <name>.bak-omaraptor-$STAMP first."
