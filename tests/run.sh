#!/usr/bin/env bash
# Offline checks: syntax, manifest, and install / uninstall in a throwaway HOME.
# Needs bash, jq, script (util-linux) and luac (or luajit). Never touches your real home.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok() { printf 'ok   %s\n' "$*"; }
bash -n "$R"/install.sh "$R"/uninstall.sh "$R"/plugin/run "$R"/bin/omaraptor; ok "bash syntax"
if command -v luac >/dev/null; then for f in "$R"/config/scripts/*.lua; do luac -p "$f"; done; ok "lua syntax"
elif command -v luajit >/dev/null; then for f in "$R"/config/scripts/*.lua; do luajit -bl "$f" >/dev/null; done; ok "lua syntax"; fi
jq -e '.schemaVersion == 1 and .id == "io.github.karpage.omaraptor" and .entryPoints.barWidget == "BarWidget.qml"' "$R/manifest.json" >/dev/null; ok "manifest"
[[ $(jq -r .version "$R/manifest.json") == "$(cat "$R/VERSION")" ]]; ok "version match"
[[ -z $(find "$R" -type l -not -path '*/.git/*') ]]; ok "no symlinks"

mkdir -p "$T/home/.config/hypr" "$T/stub" "$T/outside"
printf -- '-- user config\n' > "$T/home/.config/hypr/hyprland.lua"
for c in hyprctl notify-send update-desktop-database; do printf '#!/bin/sh\nexit 0\n' > "$T/stub/$c"; chmod +x "$T/stub/$c"; done
run() { env -i PATH="$T/stub:/usr/bin:/bin" HOME="$T/home" "$@" >/dev/null; }
mkdir -p "$T/h2/.config/hypr"; printf -- "-- user\n" > "$T/h2/.config/hypr/hyprland.lua"
env -i PATH="$T/stub:/usr/bin:/bin" HOME="$T/h2" bash "$R/install.sh" </dev/null >/dev/null
! grep -q hypr.omaraptor "$T/h2/.config/hypr/hyprland.lua"; ok "no terminal, no hyprland.lua edit"
printf "y\n" | run script -qec "bash $R/install.sh" /dev/null
[[ -x $T/home/.local/bin/omaraptor && -f $T/home/.config/omaraptor/scripts/omaraptor-hud.lua ]]; ok "install"
run bash "$R/install.sh" </dev/null
[[ $(grep -cx 'require("hypr.omaraptor")' "$T/home/.config/hypr/hyprland.lua") == 1 ]]; ok "require line once"
mkdir -p "$T/outside/omaraptor/scripts"; touch "$T/outside/omaraptor/scripts/omaraptor-hud.lua" "$T/outside/keep"
run env XDG_CONFIG_HOME="$T/outside" bash "$R/uninstall.sh" --purge
[[ -f $T/outside/omaraptor/scripts/omaraptor-hud.lua ]]; ok "purge refuses a config outside HOME"
rm -f "$T/home/.local/bin/omaraptor"; mkdir -p "$T/home/.local/bin"; ln -s "$T/outside/keep" "$T/home/.local/bin/omaraptor"
run bash "$R/uninstall.sh" --purge
[[ -f $T/outside/keep && ! -e $T/home/.local/bin/omaraptor && ! -e $T/home/.config/omaraptor ]]; ok "uninstall removes links, never their targets"
! grep -q 'hypr.omaraptor' "$T/home/.config/hypr/hyprland.lua"; ok "require line removed"
echo "all checks passed"
