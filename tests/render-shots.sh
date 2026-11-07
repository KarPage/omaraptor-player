#!/usr/bin/env bash
# Still frames of the HUD. Needs lua5.1, ffmpeg and the HUD fonts. Not run by CI.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-/tmp/omr-shots}
mkdir -p "$OUT" "$HOME/.config/fontconfig/conf.d"
cat >"$HOME/.config/fontconfig/conf.d/10-omaraptor-alias.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>JetBrainsMono Nerd Font</family>
    <prefer><family>JetBrains Mono</family></prefer>
  </alias>
</fontconfig>
EOF
fc-cache -f >/dev/null
L=$(command -v lua5.1 || command -v lua)
OMR_NIGHT_NOSAVE=1 "$L" "$R/tests/render-shots.lua" "$R/config/scripts/omaraptor-hud.lua" "$OUT"

make_bg() {
  local w=$1 h=$2 dest=$3 sky=$((h * 2 / 5))
  ffmpeg -nostdin -y -loglevel error -f lavfi -i "color=c=0x14301c:s=${w}x${h}:r=1,format=rgb24" -frames:v 1 -vf \
    "geq=r='clip(48+72*sin(X/37)+36*sin(Y/23)+24*sin((X+Y)/17),0,210)':g='clip(78+96*sin(X/29)+44*sin(Y/19)+18*sin(X/13),0,220)':b='clip(28+22*sin(X/41)+16*sin(Y/27),0,120)',drawbox=x=0:y=0:w=${w}:h=${sky}:color=0x6a9ec8@0.72:t=fill" \
    "$dest"
}

grade() {
  local night=$1 src=$2 dest=$3
  if [[ $night == off ]]; then cp "$src" "$dest"; return; fi
  if [[ $night == dim ]]; then
    ffmpeg -nostdin -y -loglevel error -i "$src" -frames:v 1 -vf "eq=brightness=-0.10:gamma=1.15:saturation=0.78,colorbalance=rs=0.07:gs=0.02:bs=-0.08" "$dest"
  else
    ffmpeg -nostdin -y -loglevel error -i "$src" -frames:v 1 -vf "eq=brightness=-0.24:gamma=0.82:saturation=0.62,colorbalance=rs=0.10:gs=0.01:bs=-0.12" "$dest"
  fi
}

while read -r name w h night pin; do
  bg=$OUT/$name.bg.png
  graded=$OUT/$name.graded.png
  make_bg "$w" "$h" "$bg"
  grade "$night" "$bg" "$graded"
  vf="ass=$OUT/$name.hud.ass"
  if [[ -s $OUT/$name.veil.ass ]] && grep -q '^Dialogue:' "$OUT/$name.veil.ass"; then
    vf="ass=$OUT/$name.veil.ass,$vf"
  fi
  ffmpeg -nostdin -y -loglevel error -i "$graded" -frames:v 1 -vf "$vf" "$OUT/$name.png"
  echo "png  $OUT/$name.png"
done <"$OUT/manifest.txt"
