#!/usr/bin/env bash
# OmaRaptor Player uninstaller. Keeps your settings unless --purge. Never stops a running player.
# It only removes files it installed, and refuses any path that does not resolve inside $HOME.
set -euo pipefail
BIN=${XDG_BIN_HOME:-$HOME/.local/bin}; CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}; HYPR=$CFG/hypr; STAMP=$(date +%Y%m%d%H%M%S)
purge=0; [[ ${1:-} == --purge ]] && purge=1
HOME_REAL=$(readlink -f "$HOME")
[[ -n $HOME_REAL && $HOME_REAL != / ]] || { echo "refusing: HOME is not set to a real home folder" >&2; exit 1; }

# inside_home <path>: its real folder (symlinks resolved) sits under $HOME. A symlink itself is
# removed, never the file it points to.
inside_home() { local d; d=$(readlink -m -- "$(dirname -- "$1")") || return 1; [[ $d == "$HOME_REAL" || $d == "$HOME_REAL"/?* ]]; }
rm_file() {
  local f
  for f in "$@"; do
    [[ -e $f || -L $f ]] || continue
    if ! inside_home "$f"; then echo "  skipped (outside $HOME): $f" >&2; continue; fi
    [[ -d $f && ! -L $f ]] && { echo "  skipped (folder): $f" >&2; continue; }
    rm -f -- "$f" && echo "  removed $f"
  done
}

echo "OmaRaptor Player: uninstall"
if [[ -f $HYPR/hyprland.lua ]] && inside_home "$HYPR/hyprland.lua" && grep -qx 'require("hypr.omaraptor")' "$HYPR/hyprland.lua"; then
  cp -p "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak-omaraptor-$STAMP"
  sed -i -e '/^-- OmaRaptor Player (remove these two lines to disable)$/d' -e '/^require("hypr\.omaraptor")$/d' "$HYPR/hyprland.lua"
  echo "  removed the require line from $HYPR/hyprland.lua (backup: hyprland.lua.bak-omaraptor-$STAMP)"
fi
rm_file "$HYPR/omaraptor.lua" "$BIN/omaraptor" "$DATA/applications/omaraptor.desktop" \
  "$DATA/icons/hicolor/scalable/apps/omaraptor.svg" "$DATA"/icons/hicolor/{48x48,128x128,256x256}/apps/omaraptor.png
conf="$CFG/omaraptor"
if ((purge)); then
  real=$(readlink -m -- "$conf")
  if [[ -d $conf && ! -L $conf && $real == "$HOME_REAL"/?*/omaraptor ]] && [[ -f $conf/scripts/omaraptor-hud.lua || -f $conf/.installed-version || -f $conf/script-opts/omaraptor-hud.conf ]]; then
    rm -rf -- "$real" && echo "  removed $real"
  elif [[ -e $conf ]]; then
    echo "  skipped $conf (not an OmaRaptor config folder inside $HOME)" >&2
  fi
else
  rm_file "$conf/scripts/omaraptor-hud.lua" "$conf/scripts/omaraptor-autoplay.lua" "$conf/.installed-version"
  echo "  kept your settings in $conf (./uninstall.sh --purge removes them)"
fi
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" 2>/dev/null || true
command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
echo "done."
