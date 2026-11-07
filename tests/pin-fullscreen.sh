#!/usr/bin/env bash
# Pin defaults off, the dispatcher only fires when the state actually changes,
# and fullscreen still reaches mpv both pinned and unpinned.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

grep -q 'pin = false' "$R/hypr/omaraptor.lua" || fail "window rule is not pin = false"
grep -q 'allow_pin_fullscreen = true' "$R/hypr/omaraptor.lua" || fail "allow_pin_fullscreen missing"
grep -q 'night=off' "$R/config/script-opts/omaraptor-hud.conf" || fail "script-opts night default"
grep -E '^\][[:space:]]' "$R/config/input.conf" >/dev/null || fail "next video is not on ]"
if grep -E '^n[[:space:]]' "$R/config/input.conf" >/dev/null; then fail "n is still bound in input.conf"; fi
awk '/^place_over\(\)/,/^}/' "$R/bin/omaraptor" | grep -vE '^[[:space:]]*#' | grep -q 'pin' && fail "place_over still pins"
grep -vE '^[[:space:]]*#' "$R/install.sh" | grep -E 'pkill|killall|[[:space:]]kill[[:space:]]|"quit"' && fail "install.sh signals a player"
echo ok static

mkdir -p "$T/bin" "$T/run"
cat >"$T/bin/hyprctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$HYPR_LOG"
case $1 in
  clients) cat "$CLIENTS" ;;
  activewindow) printf '%s\n' '{}' ;;
  monitors) cat "$MONITORS" ;;
  *) printf '%s\n' ok ;;
esac
EOF
cat >"$T/bin/socat" <<'EOF'
#!/bin/bash
cat >>"$IPC_LOG"
printf '%s\n' '{"error":"success","data":4242}'
EOF
chmod +x "$T/bin/hyprctl" "$T/bin/socat"
cat >"$T/monitors.json" <<'EOF'
[{"id":0,"width":1920,"height":1080,"scale":1,"transform":0,"reserved":[0,0,0,40],"x":0,"y":0}]
EOF
python3 - <<PY
import socket
p = "$T/run/omaraptor-$UID-4242.sock"
s = socket.socket(socket.AF_UNIX)
s.bind(p)
PY

write_client() {
  local pinned=$1 fs=$2
  cat >"$T/client.json" <<EOF
[{"address":"0xabc","class":"omaraptor","pid":4242,"pinned":$pinned,"floating":true,"fullscreen":$fs,"focusHistoryID":1,"monitor":0,"at":[120,80],"size":[614,345],"tags":[]}]
EOF
}

run() {
  : >"$T/hypr.log"
  : >"$T/ipc.log"
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" XDG_RUNTIME_DIR="$T/run" \
    HYPR_LOG="$T/hypr.log" IPC_LOG="$T/ipc.log" CLIENTS="$T/client.json" MONITORS="$T/monitors.json" \
    "$R/bin/omaraptor" "$@"
}

pins() { grep -c 'window.pin\|dispatch pin ' "$T/hypr.log" || true; }

write_client false 0
out=$(run pin on)
[[ $out == on ]] || fail "pin on printed $out"
[[ $(pins) == 1 ]] || fail "pin on should dispatch once, got $(pins)"

write_client true 0
out=$(run pin on)
[[ $out == on ]] || fail "pin on while pinned printed $out"
[[ $(pins) == 0 ]] || fail "pin on while already pinned dispatched"

out=$(run pin query)
[[ $out == on ]] || fail "query printed $out"
[[ $(pins) == 0 ]] || fail "query dispatched"

out=$(run pin off)
[[ $out == off ]] || fail "pin off printed $out"
[[ $(pins) == 1 ]] || fail "pin off should dispatch once, got $(pins)"

write_client false 0
out=$(run pin query)
[[ $out == off ]] || fail "query off printed $out"
[[ $(pins) == 0 ]] || fail "query off dispatched"

for pinned in false true; do
  write_client "$pinned" 0
  run fullscreen
  grep -q 'set_property","fullscreen",true' "$T/ipc.log" || fail "fullscreen ipc missing while pinned=$pinned"
  [[ $(pins) == 0 ]] || fail "fullscreen dispatched pin while pinned=$pinned"
done
echo ok pin-fullscreen
