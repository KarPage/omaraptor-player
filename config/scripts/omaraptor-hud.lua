-- omaraptor-hud: one-line control bar for the omaraptor mpv player, centered on the bottom edge.
--
--   [ -10s | > | +10s |  0:42 / 3:15  ====o--------  | VOL 80% | [-] [+] [FS] ]
--
--   -10s / play-pause / +10s, the time, a progress bar (click or drag to seek), the volume
--   (click = mute), two window-size buttons (smaller / bigger, keeps 16:9) and a fullscreen
--   toggle at the right end (expand corners when windowed, inward corners when fullscreen).
--
-- A single click on the video (outside the bar) plays / pauses; drag moves, double-click = fullscreen.
-- Shows when the mouse moves over the video and stays up while paused; during playback it
-- fades out ~7 s after the mouse stops (or at once when the mouse leaves). Clicks are only
-- captured on the bar: everywhere else a left-drag still moves the window and a double-click
-- still toggles fullscreen. The bar scales with the window and never covers the middle.
--
-- Options (~/.config/omaraptor/script-opts/omaraptor-hud.conf, or --script-opts=omaraptor-hud-KEY=VALUE):
--   timeout=7        seconds without mouse movement before it fades out (while playing)
--   accent=2EE6A6    RRGGBB accent colour (jade by default)
--   size=1.0         overall scale
--
-- Script messages (input.conf / IPC):
--   script-message omaraptor-hud flash [label]
--   script-message omaraptor-hud resize larger|smaller|cycle|small|medium|large
--   script-message omaraptor-hud tips [open|close]   keyboard & mouse tips panel (also ? / h keys)
--   script-message omaraptor-hud prompt              ask for a YouTube link (empty "new" windows)
--
-- The "?" square in the top-right corner (shown with the bar) opens the tips panel. Its list is
-- read live from ~/.config/hypr/omaraptor.lua and this player's input.conf, so it stays accurate.
-- The "+" square in the top-left corner opens another, empty omaraptor window ("omaraptor new"),
-- which asks for a link: paste it (Super+V, Ctrl+V or Ctrl+Shift+V), Enter plays, Esc closes.

local mp_opts = require "mp.options"
-- fast assdraw: same output bytes as mp.assdraw (scale 4), but builds into a table and joins
-- once (mp.assdraw re-copies the whole text on every coordinate: O(n^2) + heavy GC per frame)
local assdraw
do
  local fmt, ceil, concat = string.format, math.ceil, table.concat
  local A = {}
  local MT = { __index = function(t, k)
    if k == "text" then return concat(t.b, "", 1, t.n) end
    return A[k]
  end }
  local function put(t, s) local n = t.n + 1; t.b[n] = s; t.n = n end
  function A.append(t, s) if s ~= "" then put(t, s); t.any = true end end
  function A.new_event(t) if t.any then put(t, "\n") end end
  function A.draw_start(t) put(t, "{\\p4}"); t.any = true end
  function A.draw_stop(t) put(t, "{\\p0}"); t.any = true end
  function A.coord(t, x, y) put(t, fmt(" %d %d", ceil(x * 8), ceil(y * 8))); t.any = true end
  function A.move_to(t, x, y) put(t, fmt(" m %d %d", ceil(x * 8), ceil(y * 8))); t.any = true end
  function A.line_to(t, x, y) put(t, fmt(" l %d %d", ceil(x * 8), ceil(y * 8))); t.any = true end
  function A.rect_cw(t, x0, y0, x1, y1)
    local a, b, c, d = ceil(x0 * 8), ceil(y0 * 8), ceil(x1 * 8), ceil(y1 * 8)
    put(t, fmt(" m %d %d l %d %d l %d %d l %d %d", a, b, c, b, c, d, a, d)); t.any = true
  end
  assdraw = { ass_new = function() return setmetatable({ b = {}, n = 0, any = false, scale = 4 }, MT) end }
end
local utils = require "mp.utils"

local opts = { position = "bottom", timeout = 7, accent = "2EE6A6", size = 1.0, prompt = false, style = "f22", title = "top", eq = true,
  light_mode = false, pin = false }   -- pin=yes: start with the frame + bar pinned on; light_mode=yes: start in HUD LIGHT (bare player); H / HUD tile toggles
mp_opts.read_options(opts, "omaraptor-hud")
local hud = { light = opts.light_mode and true or false, pin = opts.pin and true or false }   -- pin: frame + bar never auto-hide (session)   -- COMBAT (full) / CRUISE (light), per player, kept for the session
local function boot_ok(k) return not hud.boot or mp.get_time() - hud.boot >= k * 0.1 end   -- COMBAT power-on stagger

local SECTION = "omaraptor-hud-input"
local HELP_SECTION = "omaraptor-hud-help"    -- the "?" button (one mouse area per section)
local TIPS_SECTION = "omaraptor-hud-tips"    -- whole window while the tips panel is open
local NEW_SECTION = "omaraptor-hud-new"      -- the "+" button (new window)
local TAPES = { htape = "omaraptor-hud-htape", vtape = "omaraptor-hud-vtape", ttape = "omaraptor-hud-ttape",  -- fullscreen tapes
  spd = "omaraptor-hud-spd" }                -- SPEED box: same click routing plus wheel = speed step
local SPD_STEPS = { 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2 }   -- the 7 cells of the SPEED bar, left to right
local FADE_STEPS, FADE_TIME = 4, 0.14   -- fast pop in / quick fade out (~140 ms)
local OMARAPTOR = os.getenv("OMARAPTOR_BIN") or ((os.getenv("HOME") or "") .. "/.local/bin/omaraptor")

local ov = mp.create_osd_overlay("ass-events")
ov.z = 20   -- above the empty window's link panel
local fpm = { t = -10, paused = false, timer = nil, ready = false }   -- f22 flight-path-marker flash
-- REM countdown: interpolates time-pos between frames so the hundredths run smoothly while playing
local remfx = { pos = nil, at = 0, timer = nil }
mp.observe_property("time-pos", "number", function(_, v) remfx.pos = v; remfx.at = mp.get_time() end)
local state = {
  visible = false, fade = 0, buttons = {}, panel = nil, hot = nil, section_on = false,
  dragging = false, last_seek = 0,
  mx = nil, my = nil, grab_dy = 0, grab_box = false, drag_moved = false, seek_from = nil, seek_tgt = nil,
}
-- LIVE: yt-dlp says is_live for this URL (checked once per file + duration state), or a network
-- stream with no duration. Live streams get no REM / NEXT countdown and no TIME tape.
local live = { key = nil, on = false }
local function is_live()
  local path = mp.get_property("path")
  if not path then return false end
  local dur = mp.get_property_number("duration")
  local key = path .. ((dur and dur > 0) and "|d" or "|n")
  if live.key ~= key then
    live.key, live.on = key, false
    local r = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    local out = type(r) == "table" and type(r.stdout) == "string" and r.stdout or ""
    if out:find('"is_live": true', 1, true) and out:find(path, 1, true) then live.on = true end
  end
  if live.on then return true end
  local dur2 = mp.get_property_number("duration")
  return (not dur2 or dur2 <= 0) and mp.get_property_bool("demuxer-via-network") == true
    and mp.get_property_number("time-pos") ~= nil
end
local hide_timer, fade_timer, tick_timer
-- audio signal meter: real levels from an astats filter (labelled @ytfeq) read via af-metadata
-- lv = displayed level (fast attack, 36 dB/s release), pk = peak-hold cell (0.6 s, then falls 24 dB/s)
local linkh = { t = 0 }                     -- BUFFER box history: cache seconds, sampled at 4 Hz
local eq = { lv = { -90, -90, -90 }, pk = { -90, -90, -90 }, pkt = { 0, 0, 0 }, t = 0, have = false, timer = nil }

-- colours ----------------------------------------------------------------------------------
local function bgr(hex)
  hex = tostring(hex):gsub("^#", "")
  if not hex:match("^%x%x%x%x%x%x$") then hex = "2EE6A6" end
  return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end
local ACCENT = bgr(opts.accent)
local PROG_STOPS = { { 0, ACCENT }, { 0.40, "FFFFFF" }, { 0.75, "5AA8C9" }, { 1, "4B64C8" } }   -- BGR: jade (accent), white, amber #C9A85A, rust #C8644B
local function prog_col(f)                      -- progress colour, linear per BGR channel between stops
  f = math.max(0, math.min(1, f or 0))
  for i = 2, #PROG_STOPS do
    local s0, s1 = PROG_STOPS[i - 1], PROG_STOPS[i]
    if f <= s1[1] then
      local t = (f - s0[1]) / (s1[1] - s0[1])
      local out = ""
      for k = 1, 5, 2 do
        local c0, c1 = tonumber(s0[2]:sub(k, k + 1), 16), tonumber(s1[2]:sub(k, k + 1), 16)
        out = out .. string.format("%02X", math.floor(c0 + (c1 - c0) * t + 0.5))
      end
      return out
    end
  end
  return PROG_STOPS[#PROG_STOPS][2]
end
local function a(base)  -- ASS alpha (00 opaque .. FF clear), faded by state.fade
  local v = 255 - math.floor((255 - base) * state.fade + 0.5)
  return string.format("%02X", math.max(0, math.min(255, v)))
end

local function fmt_time(t)
  if not t or t < 0 then return "--:--" end
  t = math.floor(t)
  local hh, mm, ss = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
  if hh > 0 then return string.format("%d:%02d:%02d", hh, mm, ss) end
  return string.format("%d:%02d", mm, ss)
end

-- geometry ---------------------------------------------------------------------------------
-- Three looks share one model (script-opts omaraptor-hud-style=edge|frame|segment, or
-- "script-message omaraptor-hud style NAME" live): a full-width seek line on its own row, and
-- under it one row of frosted square buttons: big transport centred (play largest), sound +
-- readout left, size / fullscreen right. Hover = jade outline, press = jade flash.
local STYLES = { f22 = true, hud = true, edge = true, frame = true, segment = true }
local style = STYLES[opts.style] and opts.style or "f22"
local function HUD() return style == "hud" or style == "f22" end   -- f22 = hud + cockpit instruments
local function dtime(t)                     -- instrument digits: 07:48, 1:02:03
  t = math.max(0, math.floor(t or 0))
  local hh, mm, ss = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
  if hh > 0 then return string.format("%d:%02d:%02d", hh, mm, ss) end
  return string.format("%02d:%02d", mm, ss)
end
local MONO = "JetBrainsMono Nerd Font"
local INK = "0D110B"             -- near-black
local ERR = "757CE0"             -- soft red (E07C75), only for "not a link"
local AMBER = "5AA8C9"          -- caution: muted soft amber #C9A85A (shared: REM <=30 %, paused scope cross, HOLD button, PAUSED)
local TILE_GREEN, TILE_CORE, TILE_GRAY = "6AFF4D", "E0FFE6", "8C8C8C"   -- HUD tile: neon green #4DFF6A, core #E6FFE0, gray (BGR)
local ALERT = "4848F0"          -- countdown critical: red #F04848
local RUST = "4B64C8"           -- mute state: soft rust #C8644B (not alarm red)
local RUST_CORE = "C8D2F5"      -- pale rust core for the neon MUTED
local function idle_empty_now()
  return mp.get_property_bool("idle-active") and (mp.get_property_number("playlist-count") or 0) == 0
end

-- status readout (replaces the corner OSD text for the bar's own actions)
local status = { text = nil, until_t = 0 }
local function set_status(s, secs) status.text = s; status.until_t = mp.get_time() + (secs or 0.9) end
local function status_text()
  if status.text and mp.get_time() < status.until_t then return status.text end
  if mp.get_property_bool("pause") then return "PAUSED" end
end

-- press effect: a jade fill that fades out over FX seconds
local FX = 0.15
local press_fx, fx_timer = { name = nil, t = 0, hold = false }, nil
local render
-- frame limiter: every animation clock (REM, ticker, meter, scope, blink) asks for a frame via
-- want(); they all share one render per ~40 ms instead of each drawing the whole HUD
local frame = { t = -1, pend = nil }
local function want()
  if frame.pend then return end
  local dt = mp.get_time() - frame.t
  if dt >= 0.036 then render(); return end
  frame.pend = mp.add_timeout(0.04 - dt, function()
    frame.pend = nil
    if mp.get_time() - frame.t >= 0.03 then render() end
  end)
end
local function press_flash(name, hold)
  press_fx.name, press_fx.t, press_fx.hold = name, mp.get_time(), hold or false
  if fx_timer then fx_timer:kill(); fx_timer = nil end
  if hold then return end
  fx_timer = mp.add_periodic_timer(1 / 60, function()
    if mp.get_time() - press_fx.t > FX + 0.03 then
      fx_timer:kill(); fx_timer = nil; press_fx.name = nil
    end
    render()
  end)
end
local function fx_k(name)
  if press_fx.name ~= name then return 0 end
  if press_fx.hold then return 1 end
  return math.max(0, 1 - (mp.get_time() - press_fx.t) / FX)
end

local function layout(w, h)
  local FSM = style == "f22" and mp.get_property_bool("fullscreen")   -- fullscreen cockpit
  local u = math.floor(math.max(20, math.min(38, h * 0.075)) * opts.size + 0.5)  -- button square
  if FSM then u = math.floor(math.max(38, math.min(88, h * 0.042)) * opts.size + 0.5) end  -- ~2x, resolution-aware
  local g = math.max(4, math.floor(u * 0.22 + 0.5))
  local fs = math.max(10, math.floor(u * 0.48 + 0.5))
  local t = math.max(1, math.floor(u / 32 + 0.5))                                  -- hairline
  local st = math.max(2, math.floor(u * 0.07 + 0.5))                               -- seek line
  local bottom = math.max(20, math.floor(h * (FSM and 0.055 or 0.04)))   -- safe margins
  local side = math.max(20, math.floor(w * (FSM and 0.045 or 0.03)))
  local cs = math.floor(u * 0.9)
  local b = {}
  b.new = { x = side, y = bottom, w = cs, h = cs }
  b.help = { x = w - side - cs, y = bottom, w = cs, h = cs }
  local p = { u = u, g = g, fs = fs, t = t, st = st, x = 0, y = 0, w = 0, h = 0, FS = FSM, side = side, bottom = bottom }
  if idle_empty_now() then return p, b end          -- empty "new" window: corner buttons only
  local boxed = style == "frame" or HUD()
  local pad = boxed and math.floor(u * 0.45) or 0
  local cx0, cx1
  if HUD() then
    cx0, cx1 = side + pad, w - side - pad
  elseif style == "frame" then
    local pw = math.min(w - 2 * side, math.max(math.floor(w * 0.84), u * 14))
    cx0 = math.floor((w - pw) / 2) + pad; cx1 = cx0 + pw - 2 * pad
  else
    cx0, cx1 = side, w - side
  end
  -- transport centred and large (play largest); sound + readout left, size + fullscreen right
  local P, T, S = math.floor(u * 1.75), math.floor(u * 1.3), math.floor(u * 0.82)
  local by = h - bottom - pad - P                   -- top of the button row
  local cy = by + P / 2
  local tg = math.floor(g * 1.2) + (style == "f22" and math.floor(P * 0.24) or 0)   -- f22: room for the dial rings
  local cxm = math.floor((cx0 + cx1) / 2)
  local px = cxm - math.floor(P / 2)
  b.play = { x = px, y = by, w = P, h = P }
  b.back = { x = px - tg - T, y = math.floor(cy - T / 2), w = T, h = T }
  b.fwd = { x = px + P + tg, y = math.floor(cy - T / 2), w = T, h = T }
  local lab = HUD() and math.floor(fs * 0.95) or 0   -- tiny labels under side buttons
  local sy0 = math.floor(cy - (S + lab) / 2)
  p.laby = sy0 + S + math.floor(lab * 0.55)
  local lgap = boxed and 0 or math.floor(g * 0.8)
  local room_l = b.back.x - g * 2 - cx0
  local volw = style == "f22" and S or math.floor(S * 2.1)   -- f22: the speaker is the MUTE softkey
  local EQ = opts.eq and not hud.light                -- LIGHT: no signal meter (plain MUTE key + VOL slider)
  if style == "f22" and EQ and room_l - math.floor(S * 3.2) >= u * 7 then
    volw = math.floor(S * 3.2)                    -- f22 + eq: the MUTE softkey is the live signal meter
  end
  local room_r = cx1 - (b.fwd.x + T) - g * 2
  local right = { "smaller", "larger", "fs" }
  if style == "f22" then right = { "pin", "hud", "smaller", "larger", "fs" } end   -- PIN + HUD FULL / LIGHT tiles
  if #right * S + (#right - 1) * lgap > room_r then right = style == "f22" and { "pin", "hud", "fs" } or { "fs" } end
  if #right * S + (#right - 1) * lgap > room_r then right = style == "f22" and { "hud", "fs" } or { "fs" } end
  if volw > room_l then volw = S end
  b.vol = { x = cx0, y = sy0, w = volw, h = S }
  p.hero = nil
  if style == "f22" and EQ and room_l >= u * 8 then
    -- hero left zone: [ signal meter = MUTE key ]  G  [ VOL slider box ]  G  [ -10 ], all T tall
    local G = math.max(g * 2, math.floor(u * 0.36))
    local L = b.back.x - G - cx0
    local mw = math.floor((L - G) * 0.6)
    b.vol = { x = cx0, y = b.back.y, w = mw, h = T }
    p.hero = { x = cx0 + mw + G, y = b.back.y, w = L - G - mw, h = T, G = G }
    volw = mw
  end
  p.mid = { x = cx0 + volw + g, w = math.max(0, room_l - volw - g), cy = HUD() and sy0 + S / 2 or cy }
  local x = cx1
  for i = #right, 1, -1 do
    local k = right[i]
    x = x - S; b[k] = { x = x, y = sy0, w = S, h = S }; x = x - lgap
  end
  local sy = by - math.floor(u * 0.55)              -- seek row, above the buttons
  if style == "f22" then sy = sy - math.floor(fs * 1.2) end   -- room for the chrono scale numbers
  local lx0, lx1 = cx0, cx1
  if style == "edge" then                           -- times at the two ends of the line
    local tw = math.floor(#fmt_time(mp.get_property_number("duration")) * fs * 0.62)
    p.tl, p.tr = { x = cx0, y = sy }, { x = cx1, y = sy }
    lx0, lx1 = cx0 + tw + g, cx1 - tw - g
  end
  b.seek = { x = lx0, y = sy - math.floor(u * 0.32), w = lx1 - lx0, h = math.floor(u * 0.64), cy = sy }
  local top = sy - math.floor(u * 0.45)
  if boxed then top = sy - pad - math.floor(u * 0.15) end
  if HUD() then top = top - math.floor(fs * (style == "f22" and 2.0 or 1.3)) end   -- room for the digital readout
  p.tth = 0
  if style == "f22" then
    local nb, hb = b.new, b.help
    p.nav = { x0 = nb.x + nb.w + g * 2, x1 = hb.x - g * 2, y0 = nb.y, h = nb.h }
    p.nav.dy = nb.y + nb.h + math.floor(fs * 0.85)           -- data line under the title strip
    local lf, lh = math.floor(fs * 0.7), math.floor(S * 0.66)
    local ly = math.floor(sy0 + (S - lh) / 2)
    p.lf = lf
    local gx0, gx1 = b.vol.x + b.vol.w + g, b.back.x - g * 2   -- VOL gauge: click / drag sets volume
    local gw = math.min(gx1 - gx0, math.floor(u * 4))
    if p.hero then                                  -- slider track inside the VOL box (lower half)
      local hb, ip = p.hero, math.max(4, math.floor(T * 0.14))
      local tw = math.floor(T * 0.2)
      p.hero.ip, p.hero.hh = ip, math.floor(fs * 1.05)
      b.vgauge = { x = hb.x + ip + tw, y = hb.y + ip + p.hero.hh, w = hb.w - 2 * (ip + tw), h = hb.h - 2 * ip - p.hero.hh }
      local cap = math.floor(fs * 0.95)               -- meter: letter column + caption strip
      p.eq = { x = b.vol.x + ip + math.floor(fs * 0.9), y = b.vol.y + ip, w = b.vol.w - 2 * ip - math.floor(fs * 0.9),
        h = T - 2 * ip - cap, cap = cap, lx = b.vol.x + ip, big = true, tile = b.vol }
    elseif gw > u * 1.6 then b.vgauge = { x = gx0, y = ly, w = gw, h = lh } end
    if p.hero then
    elseif EQ and b.vol.w > S then                 -- signal meter inset inside the MUTE tile
      local ip = math.max(3, math.floor(S * 0.16))
      p.eq = { x = b.vol.x + ip, y = b.vol.y + ip, w = b.vol.w - 2 * ip, h = S - 2 * ip }
    end
    p.rhero = nil
    if p.hero then           -- right zone mirrors the left: [SPD][REPEAT][BUFFER][SIZE - + FS], all T tall
      local G, ip = p.hero.G, p.hero.ip
      local xr0, xr1 = b.fwd.x + T + G, cx1
      local cap = math.floor(fs * 0.9)
      local bs = math.max(14, math.min(S, T - 2 * ip - cap))
      local gi = math.max(3, math.floor(bs * 0.18))
      local gw2 = 5 * bs + 4 * gi + 2 * ip + 4           -- PIN + HUD + SIZE - + + FS
      local R = xr1 - xr0 - gw2 - 3 * G
      if R >= u * 6 then
        local ws, wl = math.floor(R * 0.37), math.floor(R * 0.24)
        local wb = R - ws - wl
        local y0 = b.fwd.y
        b.spd = { x = xr0, y = y0, w = ws, h = T }
        b.loop = { x = xr0 + ws + G, y = y0, w = wl, h = T }
        b.link = { x = b.loop.x + wl + G, y = y0, w = wb, h = T }; p.link = b.link
        local gx = b.link.x + wb + G
        p.rgrp = { x = gx, y = y0, w = xr1 - gx, h = T, ip = ip, cap = cap }
        local bx = gx + math.floor((xr1 - gx - (5 * bs + 4 * gi)) / 2)
        local byy = y0 + ip
        b.pin = { x = bx, y = byy, w = bs, h = bs }; bx = bx + bs + gi
        b.hud = { x = bx, y = byy, w = bs, h = bs }; bx = bx + bs + gi
        b.smaller = { x = bx, y = byy, w = bs, h = bs }
        b.larger = { x = bx + bs + gi, y = byy, w = bs, h = bs }
        b.fs = { x = bx + 2 * (bs + gi), y = byy, w = bs, h = bs }
        p.rhero = { ip = ip }
      end
    end
    local function lw(txt) return math.floor(#txt * lf * 0.62 + lf * 1.3) end
    local x, xmax = b.fwd.x + T + g * 2, (b.pin or b.hud or b.smaller or b.fs).x - g * 2
    if p.rhero or hud.light then xmax = x - 1 end   -- boxes already placed / LIGHT: no SPD LOOP LINK lamps
    for _, it in ipairs({ { "spd", "SPD 1.00x" }, { "loop", "LOOP" } }) do
      local wv = lw(it[2])
      if x + wv <= xmax then b[it[1]] = { x = x, y = ly, w = wv, h = lh }; x = x + wv + g end
    end
    local wl = lw("LINK 00s") + lf
    if not p.rhero and x + wl <= xmax then p.link = { x = x, y = ly, w = wl, h = lh }; b.link = p.link end   -- press: BUFFER popup
  end
  if FSM and p.nav and not hud.light then                 -- fullscreen instruments (FULL only)
    local tw = math.floor(math.min(w * 0.42, u * 16))
    local hy = p.nav.dy + math.floor(fs * 0.9)
    b.htape = { x = math.floor((w - tw) / 2), y = hy, w = tw, h = math.floor(u * 1.25) }   -- fine-seek heading tape
    local ty0, ty1 = b.htape.y + b.htape.h + u, top - u
    local tw2 = math.floor(u * 0.9)
    if ty1 - ty0 > u * 4 then
      b.vtape = { x = side + math.floor(u * 0.2), y = ty0, w = tw2, h = ty1 - ty0 }               -- VOL (airspeed)
      b.ttape = { x = w - side - math.floor(u * 0.2) - tw2, y = ty0, w = tw2, h = ty1 - ty0 }   -- REM (altitude, countdown) / LIVE tape
      -- grab areas: column + pointer box + padding, so the box itself is draggable
      local pbh, pad = math.floor(fs * 1.6), math.floor(u * 0.5)
      local vb = b.vtape
      local vx0 = math.max(0, vb.x - pad)
      local vx1 = vb.x + vb.w + 2 + math.floor(pbh * 0.35) + math.floor(fs * 3.0) + pad
      vb.grab = { x = vx0, y = vb.y - pbh, w = vx1 - vx0, h = vb.h + 2 * pbh }
      local tb = b.ttape
      if tb then
        local tx0 = tb.x - 2 - math.floor(pbh * 0.35) - math.floor(fs * 6.6) - pad
        tb.grab = { x = tx0, y = tb.y - pbh, w = math.min(w, tb.x + tb.w + pad) - tx0, h = tb.h + 2 * pbh }
      end
    end
  end
  if style == "f22" and opts.title ~= "off" then         -- f22: the title is the top HUD data line
    p.title = { x0 = p.nav.x0 + math.floor(u * 0.4), x1 = p.nav.x1 - math.floor(u * 0.4),
      cy = p.nav.y0 + math.floor(p.nav.h / 2), fs = math.floor(fs * 1.1), an = 5 }
  elseif HUD() and opts.title == "top" then      -- (a) neon title row above the readout
    p.tth = math.floor(fs * 1.75)
    top = top - p.tth
    p.title = { x0 = cx0 + math.floor(u * 1.2), x1 = cx1 - math.floor(u * 1.2), cy = top + math.floor(u * 0.3 + fs * 0.75), fs = math.floor(fs * 1.3), an = 5 }
  elseif HUD() and opts.title == "row" then  -- (b) neon title in the button row, left of -10
    local x0 = cx0 + volw + g * 2
    local x1 = b.back.x - g * 2
    if x1 - x0 > fs * 3 then
      p.title = { x0 = x0, x1 = x1, cy = math.floor(cy), fs = math.floor(fs * 1.1), an = 4 }
    end
  end
  p.x, p.y = cx0 - pad, top
  p.w, p.h = (cx1 + pad) - p.x, (by + P + pad) - top
  p.cx0, p.cx1, p.sy, p.by = cx0, cx1, sy, by
  return p, b
end

-- drawing ----------------------------------------------------------------------------------
-- sparse shapes: libass rasterises (and mpv re-uploads on every redraw) each drawing event as ONE
-- bitmap the size of its bounding box (and mpv re-blends/uploads it on every redraw), so a hollow
-- 1 px screen frame costs a full-screen bitmap. shape() records the strokes; when every vertex is
-- on a whole pixel, strokes whose boxes don't overlap become their own event (no shared pixels, so
-- the same pixels at a fraction of the bitmap area). Only when it saves >= 40k px of bitmap.
local shape
do
  local ceil, fmt, concat, min, max = math.ceil, string.format, table.concat, math.min, math.max
  local P, n, cur, frac = {}, 0, nil, false
  local R = {}
  local function newp(s, x, y) n = n + 1; local p = P[n] or {}; P[n] = p
    p.s, p.k, p.x0, p.y0, p.x1, p.y1 = { s }, 1, x, y, x, y; cur = p
    if x % 8 ~= 0 or y % 8 ~= 0 then frac = true end
    return p end
  local function grow(p, x, y)
    if x % 8 ~= 0 or y % 8 ~= 0 then frac = true end
    if x < p.x0 then p.x0 = x elseif x > p.x1 then p.x1 = x end
    if y < p.y0 then p.y0 = y elseif y > p.y1 then p.y1 = y end
  end
  function R.move_to(_, x, y) local a, b = ceil(x * 8), ceil(y * 8); newp(fmt(" m %d %d", a, b), a, b) end
  function R.line_to(_, x, y)
    local a, b = ceil(x * 8), ceil(y * 8)
    local p = cur; p.k = p.k + 1; p.s[p.k] = fmt(" l %d %d", a, b); grow(p, a, b)
  end
  function R.rect_cw(_, x0, y0, x1, y1)
    local a, b, c, d = ceil(x0 * 8), ceil(y0 * 8), ceil(x1 * 8), ceil(y1 * 8)
    local p = newp(fmt(" m %d %d l %d %d l %d %d l %d %d", a, b, c, b, c, d, a, d), a, b); grow(p, c, d)
  end
  local par = {}
  local function find(i) while par[i] ~= i do par[i] = par[par[i]]; i = par[i] end; return i end
  shape = function(ass, color, alpha, fn, bord, bcolor, balpha)
    local head = string.format("{\\an7\\pos(0,0)\\shad0\\bord%s\\1c&H%s&\\1a&H%s&\\3c&H%s&\\3a&H%s&}",
      bord or 0, color, a(alpha), bcolor or color, a(balpha or 255))
    n, cur, frac = 0, nil, false
    fn(R)
    local groups = 1
    local big = false
    if n > 1 and n <= 64 and not frac and (tonumber(bord) or 0) == 0 then
      local X0, Y0, X1, Y1 = 1e9, 1e9, -1e9, -1e9
      for i = 1, n do local p = P[i]
        X0, Y0, X1, Y1 = min(X0, p.x0), min(Y0, p.y0), max(X1, p.x1), max(Y1, p.y1) end
      big = (X1 - X0) * (Y1 - Y0) >= 64 * 80000              -- only big shapes can save 40k px
    end
    if big then
      -- whole-pixel fills: join only boxes that overlap (touching edges share no pixel)
      for i = 1, n do par[i] = i end
      for i = 1, n do
        local p = P[i]
        for j = i + 1, n do
          local q = P[j]
          if p.x0 < q.x1 and q.x0 < p.x1 and p.y0 < q.y1 and q.y0 < p.y1 then
            local ri, rj = find(i), find(j); if ri ~= rj then par[rj] = ri end
          end
        end
      end
      groups = 0
      local X0, Y0, X1, Y1, area = 1e9, 1e9, -1e9, -1e9, 0
      for i = 1, n do
        local r = find(i)
        local p = P[i]
        X0, Y0, X1, Y1 = min(X0, p.x0), min(Y0, p.y0), max(X1, p.x1), max(Y1, p.y1)
        if r == i then groups = groups + 1 end
      end
      if groups > 12 then groups = 1 end                 -- many tiny strips: event count wins
      if groups > 1 then
        -- per-group bbox area vs the whole bbox: only split when it actually saves bitmap area
        local gb = {}
        for i = 1, n do
          local r, p = find(i), P[i]
          local b = gb[r]
          if not b then gb[r] = { p.x0, p.y0, p.x1, p.y1 } else
            b[1], b[2], b[3], b[4] = min(b[1], p.x0), min(b[2], p.y0), max(b[3], p.x1), max(b[4], p.y1) end
        end
        for _, b in pairs(gb) do area = area + (b[3] - b[1] + 16) * (b[4] - b[2] + 16) end
        local whole = (X1 - X0 + 16) * (Y1 - Y0 + 16)
        if area * 2 > whole or whole - area < 64 * 40000 then groups = 1 end  -- split only for >= 40k px saved
      end
    end
    if groups == 1 then
      ass:new_event(); ass:append(head); ass:draw_start()
      for i = 1, n do ass:append(concat(P[i].s, "", 1, P[i].k)) end
      ass:draw_stop()
      return
    end
    for i = 1, n do
      if find(i) == i then
        ass:new_event(); ass:append(head); ass:draw_start()
        for j = i, n do if find(j) == i then ass:append(concat(P[j].s, "", 1, P[j].k)) end end
        ass:draw_stop()
      end
    end
  end
end
local function mtext(ass, x, y, size, color, alpha, s, an, extra)
  ass:new_event()
  ass:append(string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\fsp0%s}%s",
    an or 5, x, y, MONO, size, color, a(alpha), extra or "", s))
end
-- status icon for the centre readout, drawn inline in the same text event (no extra event):
-- PLAYING = a small solid play triangle, PAUSED = two thin bars; ~ the old square glyph's size
local function st_icon(size, paused)
  local q = math.max(5, math.floor(size * 0.56 + 0.5))
  local d
  if paused then
    local bw = math.max(1, math.floor(q * 0.26 + 0.5)); local g = math.max(2, q - 2 * bw - math.floor(q * 0.2))
    d = string.format("m 0 0 l %d 0 l %d %d l 0 %d m %d 0 l %d 0 l %d %d l %d %d", bw, bw, q, q, bw + g, 2 * bw + g, 2 * bw + g, q, bw + g, q)
  else
    local tw = math.floor(q * 0.88 + 0.5)
    d = string.format("m 0 0 l %d %d l 0 %d", tw, math.floor(q / 2), q)
  end
  return string.format("{\\p1\\pbo%d}%s{\\p0} ", -math.floor(size * 0.04 + 0.5), d)
end
-- info line under the title: muted amber #C9A85A labels, a brighter amber for values, and a very
-- soft low-alpha deep-amber glow (#302414, blurred border on the same text event, no extra events):
-- legible on bright sky, reads as a faint warm halo on dark footage
local INFO_LBL, INFO_VAL = "5AA8C9", "7CC4DE"
local function info_glow(fs, sp)
  return string.format("\\fsp%d\\bord%.1f\\blur%.1f\\3c&H142430&\\3a&H60&", sp or 1, math.max(1.5, fs * 0.16), math.max(2, fs * 0.24))
end
-- SPEED bar cell under (x, y): the whole column below the header counts, so each cell is a tall,
-- easy target; nil on the header (label / value) row
local function spd_cell_at(r, x, y)
  local c = r and r.cells
  if not (c and x and y) or y < c.y0 then return nil end
  local i = math.floor((x - c.x0 + c.gp / 2) / (c.cw + c.gp)) + 1
  return math.max(1, math.min(c.n, i))
end
local function C(col, al) return string.format("{\\1c&H%s&\\1a&H%s&}", col, a(al)) end
local function tri(d, x1, y1, x2, y2, x3, y3) d:move_to(x1, y1); d:line_to(x2, y2); d:line_to(x3, y3) end
local function outline(d, x, y, w, h, t)
  d:rect_cw(x, y, x + w, y + t); d:rect_cw(x, y + h - t, x + w, y + h)
  d:rect_cw(x, y + t, x + t, y + h - t); d:rect_cw(x + w - t, y + t, x + w, y + h - t)
end
local function ticks(d, x, y, w, h, t, l)          -- four corner L marks
  d:rect_cw(x, y, x + l, y + t); d:rect_cw(x, y, x + t, y + l)
  d:rect_cw(x + w - l, y, x + w, y + t); d:rect_cw(x + w - t, y, x + w, y + l)
  d:rect_cw(x, y + h - t, x + l, y + h); d:rect_cw(x, y + h - l, x + t, y + h)
  d:rect_cw(x + w - l, y + h - t, x + w, y + h); d:rect_cw(x + w - t, y + h - l, x + w, y + h)
end

-- the square around a button: frosted glass (layered translucent fill, lighter top half,
-- faint inner highlight) + hairline outline; returns the colour / alpha for its glyph
local function chrome(ass, p, name, r, on)
  local hot, k = state.hot == name, fx_k(name)
  local ON = (name == "vol" and on) and RUST or ACCENT   -- muted speaker / MUTE softkey lights rust
  if name == "play" and on and style == "f22" and mp.get_property_bool("pause") then ON = AMBER end  -- HOLD = amber
  local x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
  local t = p.t
  shape(ass, INK, 0x78, function(d) d:rect_cw(x0, y0, x1, y1) end)                 -- dark glass body
  shape(ass, "FFFFFF", 0xEE, function(d) d:rect_cw(x0, y0, x1, y1) end)            -- light frost
  shape(ass, "FFFFFF", 0xF2, function(d) d:rect_cw(x0, y0, x1, math.floor(y0 + r.h * 0.48)) end) -- sheen
  shape(ass, "FFFFFF", 0xB8, function(d) d:rect_cw(x0 + t, y0 + t, x1 - t, y0 + 2 * t) end) -- inner highlight
  if hot then shape(ass, ACCENT, 0xE0, function(d) d:rect_cw(x0, y0, x1, y1) end) end
  if on then shape(ass, ON, (ON == RUST or ON == AMBER) and 0xC8 or 0xEC, function(d) d:rect_cw(x0, y0, x1, y1) end) end
  if k > 0 then
    shape(ass, ACCENT, 255 - math.floor(k * 240), function(d) d:rect_cw(x0, y0, x1, y1) end)
  end
  local col, al = "FFFFFF", 0x90
  if hot or on then col, al = (on and ON or ACCENT), 0x00 end
  shape(ass, col, al, function(d)
    outline(d, r.x, r.y, r.w, r.h, t)
    if style == "segment" or HUD() then ticks(d, r.x, r.y, r.w, r.h, t + 1, math.floor(r.h * 0.22)) end
  end)
  if k > 0.35 then return INK, 0x00 end
  if on then return ON, 0x00 end
  return "FFFFFF", hot and 0x00 or 0x10
end

local function stroke(p) return math.max(1, math.floor(p.u * 0.055 + 0.5)) end
local function g_play(ass, r, col, al, paused)
  local cx, cy, s = r.x + r.w / 2, math.floor(r.y + r.h / 2), r.h * 0.2
  shape(ass, col, al, function(d)
    if paused then tri(d, cx - 0.7 * s, cy - s, cx + s, cy, cx - 0.7 * s, cy + s)
    else
      local bw = math.max(2, math.floor(s * 0.45))
      local x1 = math.floor(cx - s * 0.7); local x2 = math.floor(cx + s * 0.7) - bw
      d:rect_cw(x1, cy - s, x1 + bw, cy + s); d:rect_cw(x2, cy - s, x2 + bw, cy + s)
    end
  end)
end
local function g_line(ass, r, col, al, plus, k)  -- thin minus / plus
  local cx, cy, l = math.floor(r.x + r.w / 2), math.floor(r.y + r.h / 2), math.floor(r.h * 0.2)
  shape(ass, col, al, function(d)
    local o = math.floor(k / 2)
    d:rect_cw(cx - l, cy - o, cx + l + (k % 2), cy - o + k)
    if plus then d:rect_cw(cx - o, cy - l, cx - o + k, cy + l + (k % 2)) end
  end)
end
local function g_fs(ass, r, col, al, full, t)
  local s = math.floor(r.h * 0.40)
  local x, y = math.floor(r.x + (r.w - s) / 2), math.floor(r.y + (r.h - s) / 2)
  local l, x1, y1 = math.floor(s * 0.36), x + s, y + s
  shape(ass, col, al, function(d)
    if not full then ticks(d, x, y, s, s, t, l)
    else
      d:rect_cw(x, y + l - t, x + l, y + l);   d:rect_cw(x + l - t, y, x + l, y + l)
      d:rect_cw(x1 - l, y + l - t, x1, y + l); d:rect_cw(x1 - l, y, x1 - l + t, y + l)
      d:rect_cw(x, y1 - l, x + l, y1 - l + t); d:rect_cw(x + l - t, y1 - l, x + l, y1)
      d:rect_cw(x1 - l, y1 - l, x1, y1 - l + t); d:rect_cw(x1 - l, y1 - l, x1 - l + t, y1)
    end
  end)
end
local function g_vol(ass, p, r, col, al, muted, vol)
  local compact = r.w < r.h * 1.5
  local s = r.h * 0.085
  local cx, cy = compact and r.x + r.w / 2 + s * 0.6 or r.x + r.h * 0.5, r.y + r.h / 2
  shape(ass, col, al, function(d)
    d:move_to(cx - 1.8 * s, cy - 0.7 * s); d:line_to(cx - 0.7 * s, cy - 0.7 * s)
    d:line_to(cx + 0.6 * s, cy - 1.8 * s); d:line_to(cx + 0.6 * s, cy + 1.8 * s)
    d:line_to(cx - 0.7 * s, cy + 0.7 * s); d:line_to(cx - 1.8 * s, cy + 0.7 * s)
  end)
  if not compact then
    mtext(ass, r.x + r.w - r.h * 0.3, cy, math.floor(p.fs * 0.95), col, al,
      muted and "off" or string.format("%d", math.floor((vol or 0) + 0.5)), 6)
  end
end

-- f22 centre dial: the one round control (play / pause) with three broken rings ------------
local function ang(cx, cy, R, deg) local t = math.rad(deg); return cx + R * math.sin(t), cy - R * math.cos(t) end
local function arc(d, cx, cy, r0, r1, a0, a1)        -- annular sector, 0 deg = 12 o'clock, clockwise
  local n = math.max(2, math.ceil(math.abs(a1 - a0) / 3))
  for i = 0, n do
    local x, y = ang(cx, cy, r1, a0 + (a1 - a0) * i / n)
    if i == 0 then d:move_to(x, y) else d:line_to(x, y) end
  end
  for i = n, 0, -1 do d:line_to(ang(cx, cy, r0, a0 + (a1 - a0) * i / n)) end
end
local function radial(d, cx, cy, r0, r1, deg, wpx)  -- thin radial tick
  local t = math.rad(deg); local nx, ny = math.cos(t) * wpx / 2, math.sin(t) * wpx / 2
  local x0, y0 = ang(cx, cy, r0, deg); local x1, y1 = ang(cx, cy, r1, deg)
  d:move_to(x0 - nx, y0 - ny); d:line_to(x1 - nx, y1 - ny); d:line_to(x1 + nx, y1 + ny); d:line_to(x0 + nx, y0 + ny)
end
local function draw_dial(ass, p, r, paused, muted)
  local P = r.h
  local cx, cy = r.x + r.w / 2, r.y + r.h / 2
  local SC = paused and AMBER or ACCENT                         -- state colour (matches the scope)
  local hot, k = state.hot == "play", fx_k("play")
  local th = math.max(1, P * 0.018)                             -- hairline weight
  local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
  if pos and remfx.cur then pos = remfx.cur(pos) or pos end
  local f = (pos and dur and dur > 0) and math.max(0, math.min(1, pos / dur)) or 0
  -- OUTER: playback progress, four quarter arcs (gaps = 25 / 50 / 75 %)
  local Ro = P * 0.64; local Ri = Ro - th
  local gq, F = 4, f * 360
  shape(ass, "FFFFFF", 0xC0, function(d) for q = 0, 3 do
    local a0 = math.max(q * 90 + gq, F)
    if a0 < q * 90 + 90 - gq then arc(d, cx, cy, Ri, Ro, a0, q * 90 + 90 - gq) end
  end end)
  if F > gq then shape(ass, SC, 0x00, function(d) for q = 0, 3 do
    local a0, a1 = q * 90 + gq, math.min(q * 90 + 90 - gq, F)
    if a1 > a0 then arc(d, cx, cy, Ri - th * 0.4, Ro + th * 0.4, a0, a1) end
  end end) end
  shape(ass, "FFFFFF", 0x10, function(d) radial(d, cx, cy, Ri - th * 2, Ro + th * 2, F, math.max(1, th)) end)   -- progress index
  -- MIDDLE: volume, 270 deg in 10 clean segments (open at the bottom)
  local Vo = P * 0.565; local Vi = Vo - th * 1.3
  local vol = math.max(0, math.min(100, mp.get_property_number("volume") or 0))
  local N, A0, SW = 10, -135, 270
  local seg = SW / N
  local lit = math.floor(vol / 100 * N + 0.5)
  local VC = muted and RUST or SC
  shape(ass, "FFFFFF", 0xD0, function(d) for i = lit, N - 1 do arc(d, cx, cy, Vi, Vo, A0 + i * seg + 2.5, A0 + (i + 1) * seg - 2.5) end end)
  if lit > 0 then shape(ass, VC, muted and 0x40 or 0x18, function(d)
    for i = 0, lit - 1 do arc(d, cx, cy, Vi, Vo, A0 + i * seg + 2.5, A0 + (i + 1) * seg - 2.5) end end) end
  -- INNER: progress ring, 24 ticks clockwise from 12 o'clock. Done ticks solid in the state colour,
  -- the building tick breathes (~1 Hz cosine, never off) until its slice completes, the rest stay dim.
  -- Paused: no breath, the building tick holds at half. LIVE: no fill (dim ring, top index only).
  -- No timer of its own: it rides the 25 Hz remfx clock that already runs while the bar is visible.
  local Rb = P * 0.41
  if P >= 56 then
    local To = P * 0.495; local Ti = To - P * 0.05
    local NT, live_now = 24, is_live()
    local done = live_now and 0 or math.min(NT, math.floor(f * NT + 1e-6))
    local wf, wd = math.max(1.5, th * 1.3), math.max(1, th * 0.8)
    shape(ass, "FFFFFF", 0xB0, function(d) for i = done + 1, NT - 1 do radial(d, cx, cy, Ti, To, i * 15, wd) end end)
    if done > 0 then shape(ass, SC, 0x00, function(d) for i = 0, done - 1 do radial(d, cx, cy, Ti, To, i * 15, wf) end end) end
    if live_now then shape(ass, SC, 0x00, function(d) radial(d, cx, cy, Ti, To, 0, wf) end)
    elseif done < NT then
      local al
      if paused then al = 0x80
      else local b = 0.5 - 0.5 * math.cos(mp.get_time() * 2 * math.pi)   -- 1 s eased breath
        al = math.floor(0x90 * (1 - b) + 0.5) end                       -- 0x90 (dim) .. 0x00 (solid)
      shape(ass, SC, al, function(d) radial(d, cx, cy, Ti, To, done * 15, wf) end)
    end
  end
  -- BUTTON: dark glass disc, one crisp rim
  shape(ass, INK, 0x60, function(d) arc(d, cx, cy, 0, Rb, 0, 360) end)
  if hot then shape(ass, SC, 0xE6, function(d) arc(d, cx, cy, 0, Rb, 0, 360) end) end
  if k > 0 then shape(ass, SC, 255 - math.floor(k * 230), function(d) arc(d, cx, cy, 0, Rb, 0, 360) end) end
  shape(ass, SC, hot and 0x00 or 0x20, function(d) arc(d, cx, cy, Rb - math.max(1, P * 0.014), Rb, 0, 360) end)
  local gc = k > 0.35 and INK or SC
  local s = P * 0.14
  shape(ass, gc, 0x00, function(d)
    if paused then tri(d, cx - 0.55 * s, cy - s, cx + s, cy, cx - 0.55 * s, cy + s)
    else
      local bw = math.max(2, math.floor(s * 0.28 + 0.5))
      local x1 = math.floor(cx - s * 0.5); local x2 = math.floor(cx + s * 0.5) - bw
      d:rect_cw(x1, cy - s, x1 + bw, cy + s); d:rect_cw(x2, cy - s, x2 + bw, cy + s)
    end
  end)
  if paused and P >= 30 then
    mtext(ass, cx, cy + Rb * 0.62, math.max(7, math.floor(P * 0.095)), gc, 0x20, "HOLD", 5, "\\fsp2")
  end
end

local function seek_frac(x)
  local r = state.buttons.seek
  if not r then return 0 end
  return math.max(0, math.min(1, (x - r.x) / r.w))
end

local function draw_seek(ass, p, r)
  local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
  local f = (pos and dur and dur > 0) and math.max(0, math.min(1, pos / dur)) or 0
  local hot = state.hot == "seek" or state.hot == "phead" or state.dragging
  local cy = r.cy
  if style == "segment" then          -- a row of small square cells
    local c = math.max(3, math.floor(p.u * 0.13))
    local n = math.max(8, math.floor((r.w + 2) / (c + math.max(2, math.floor(c * 0.55)))))
    local pitch = (r.w - c) / (n - 1)
    local on = math.floor(f * (n - 1) + 0.5)
    local y0 = math.floor(cy - c / 2)
    shape(ass, "FFFFFF", 0xB0, function(d)
      for i = on + 1, n - 1 do local x = math.floor(r.x + i * pitch); d:rect_cw(x, y0, x + c, y0 + c) end
    end)
    if on > 0 then
      shape(ass, ACCENT, 0x00, function(d)
        for i = 0, on - 1 do local x = math.floor(r.x + i * pitch); d:rect_cw(x, y0, x + c, y0 + c) end
      end)
    end
    local hx, hh = math.floor(r.x + on * pitch), math.floor(c * (hot and 3.4 or 2.6))
    shape(ass, "FFFFFF", 0x00, function(d) d:rect_cw(hx, cy - hh / 2, hx + c, cy + hh / 2) end)
  elseif style == "f22" and dur and dur > 0 then   -- rangefinder / chronograph scale
    local y0 = math.floor(cy)
    local px = math.floor(r.x + r.w * f)
    local lf = math.max(9, math.floor(p.fs * 0.74))
    local long = dur >= 3600
    local function lbl(t)
      t = math.floor(t + 0.5)
      if long then return string.format("%d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60) end
      return string.format("%02d:%02d", math.floor(t / 60), t % 60)
    end
    local lw = (long and 4 or 5) * lf * 0.62
    local NICE = { 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18000 }
    local M = NICE[#NICE]
    for _, v in ipairs(NICE) do if (dur / v) * lw * 2.9 <= r.w then M = v; break end end
    local pxs = r.w / dur                              -- pixels per second
    local labels = r.w >= p.u * 9 and M * pxs >= lw * 1.6
    local med = M * pxs / 2 >= 7
    local sub = (M % 10 == 0 or M < 10) and M / 10 or M / 5
    if M == 15 or M == 900 then sub = M / 5 end
    local minor = sub * pxs >= 4 and r.w >= p.u * 7
    local tl = math.max(3, math.floor(p.u * 0.13))
    local tm = math.max(5, math.floor(p.u * 0.24))
    local tL = math.max(7, math.floor(p.u * 0.38))
    -- base line: dim ahead, jade behind the playhead
    shape(ass, "FFFFFF", 0x98, function(d) d:rect_cw(r.x, y0, r.x + r.w, y0 + 1) end)
    if px > r.x then shape(ass, ACCENT, 0x00, function(d) d:rect_cw(r.x, y0 - 1, px, y0 + 2) end) end
    local step = minor and sub or (med and M / 2 or M)
    local n = math.floor(dur / step + 1e-6)
    local past, ahead = {}, {}
    for i = 0, n do
      local t = i * step
      local x = math.floor(r.x + t * pxs)
      local isM = math.abs(t / M - math.floor(t / M + 0.5)) < 1e-6
      local isMed = not isM and math.abs((t * 2) / M - math.floor((t * 2) / M + 0.5)) < 1e-6
      local len = isM and tL or (isMed and tm or tl)
      local list = x <= px and past or ahead
      list[#list + 1] = { x, len }
    end
    local xe = r.x + r.w                               -- end-of-tape bar
    ahead[#ahead + 1] = { xe - 1, tL }
    shape(ass, "FFFFFF", 0x88, function(d) for _, k in ipairs(ahead) do d:rect_cw(k[1], y0 + 3, k[1] + 1, y0 + 3 + k[2]) end end)
    if #past > 0 then
      shape(ass, ACCENT, 0x10, function(d) for _, k in ipairs(past) do d:rect_cw(k[1], y0 + 3, k[1] + 1, y0 + 3 + k[2]) end end)
    end
    -- heading row above the line: the run mapped to 000-360 deg (50 % = S), ticks every 15 deg,
    -- 45 deg taller; labels N 045 E 135 S 225 W 315 N on wide tapes; jade once passed
    if r.w >= p.u * 6 then
      local a, bb = {}, {}
      for i = 1, 23 do
        local x = math.floor(r.x + r.w * i / 24)
        local len = (i % 6 == 0) and 5 or ((i % 3 == 0) and 3 or 2)
        local list = x <= px and a or bb
        list[#list + 1] = { x, len }
      end
      shape(ass, "FFFFFF", 0xA8, function(d) for _, k in ipairs(bb) do d:rect_cw(k[1], y0 - 2 - k[2], k[1] + 1, y0 - 2) end end)
      if #a > 0 then shape(ass, ACCENT, 0x40, function(d) for _, k in ipairs(a) do d:rect_cw(k[1], y0 - 2 - k[2], k[1] + 1, y0 - 2) end end) end
      local cf = math.max(8, math.floor(lf * 0.78))
      if r.w >= p.u * 12 and r.w / 8 >= cf * 0.62 * 5 then
        local NAMES = { [0] = "N", [2] = "E", [4] = "S", [6] = "W", [8] = "N" }
        for i = 0, 8 do
          local x = math.floor(r.x + r.w * i / 8)
          local passed = x <= px
          local card = NAMES[i] ~= nil
          local an = i == 0 and 1 or (i == 8 and 3 or 2)
          mtext(ass, x, y0 - 4 - (i % 2 == 0 and 5 or 3), cf, passed and ACCENT or "FFFFFF",
            passed and (card and 0x00 or 0x30) or (card and 0x60 or 0x88), NAMES[i] or string.format("%03d", i * 45), an, "\\fsp1")
        end
      end
    end
    if labels then
      local ly = y0 + 4 + tL + math.floor(lf * 0.1)
      local last = -1e9
      for i = 0, math.floor(dur / M + 1e-6) do
        local t = i * M
        local x = math.floor(r.x + t * pxs)
        if x - last >= lw * 1.4 and x + lw / 2 <= xe + lw * 0.1 then
          local passed = x <= px
          local an = (i == 0) and 7 or 8
          mtext(ass, x, ly, lf, passed and ACCENT or "FFFFFF", passed and 0x00 or 0x60, lbl(t), an, "\\fsp0")
          last = x
        end
      end
    end
    -- machined index: hairline through the tape, bevelled bug head above it, riding time tag
    local W = math.max(10, math.floor(p.u * (p.FS and 0.72 or 0.44) * (hot and 1.12 or 1) / 2) * 2)   -- bigger in fullscreen
    local H = math.floor(W * 0.8)
    local c = math.max(2, math.floor(W * 0.3))
    local yb = y0 - 3                                     -- tip of the head
    local yt = yb - H - c
    local tf = math.max(9, math.floor(lf * (p.FS and 1.25 or 0.95)))
    local th2 = math.floor(tf * 1.35)
    local tyc = y0 + 4 + tL + math.floor(lf * 0.1) + math.floor(lf * 0.55)   -- centre of the label row
    local ty = math.floor(tyc - th2 / 2)
    local yl = ty                                         -- hairline runs down to the riding tag
    local gb = math.max(2, math.floor(W * 0.25))
    -- playhead: one glowing vertical line whose colour runs with progress
    -- jade (0 %) -> white (40 %) -> amber (75 %) -> rust (100 %); LIVE stays jade
    local LC = is_live() and ACCENT or prog_col(f)
    local gw = math.max(2, math.floor(W * 0.18))           -- halo half-width
    ass:new_event()                                       -- soft halo: wide, low alpha, blurred
    ass:append(string.format("{\\an7\\pos(0,0)\\shad0\\bord0\\blur%d\\1c&H%s&\\1a&H%s&}", gb, LC, a(0x70)))
    ass:draw_start(); ass:rect_cw(px - gw, yt, px + gw + 1, yl); ass:draw_stop()
    shape(ass, LC, 0x00, function(d) d:rect_cw(px - 1, yt, px + 1, yl) end)   -- thin bright core (2 px)
    -- riding time tag (07:59.482) on the scale's number row: opaque, so it occludes the minute
    -- labels as it passes over them; centred under the needle, clamped to the tape ends
    local txt, tlen = remfx.tms(remfx.cur(pos), tf, 0x50)
    local tw2 = math.floor(tlen * tf * 0.6 + tf * 0.8)
    local tx = math.max(r.x - math.floor(tf * 0.3), math.min(r.x + r.w - tw2 + math.floor(tf * 0.3), math.floor(px - tw2 / 2)))
    shape(ass, INK, 0x00, function(d) d:rect_cw(tx, ty, tx + tw2, ty + th2) end)
    shape(ass, ACCENT, 0x00, function(d)
      outline(d, tx, ty, tw2, th2, 1)
      local k = math.max(2, math.floor(th2 * 0.22))               -- pointer notch up into the needle
      if px - k >= tx and px + k <= tx + tw2 then tri(d, px - k, ty, px + k + 1, ty, px, ty - k) end
    end)
    mtext(ass, tx + tw2 / 2, ty + th2 / 2, tf, "FFFFFF", 0x00, txt, 5, "\\fsp0")
    local gx0, gx1 = math.min(px - W / 2, tx), math.max(px + W / 2, tx + tw2)
    state.buttons.phead = { x = math.floor(gx0 - 4), y = yt - 4, w = math.floor(gx1 - gx0 + 8), h = ty + th2 - yt + 8 }  -- grab target
  elseif HUD() then          -- graduated scale: 1px line, ticks, small square playhead
    local y0 = math.floor(cy)
    shape(ass, "FFFFFF", 0x98, function(d) d:rect_cw(r.x, y0, r.x + r.w, y0 + 1) end)
    local px = math.floor(r.x + r.w * f)
    if px > r.x then shape(ass, ACCENT, 0x00, function(d) d:rect_cw(r.x, y0 - 1, px, y0 + 2) end) end
    local N = 40
    local tl, tL = math.max(3, math.floor(p.u * 0.12)), math.max(6, math.floor(p.u * 0.26))
    shape(ass, "FFFFFF", 0xA0, function(d)
      for i = 0, N do
        local x = math.floor(r.x + r.w * i / N)
        if x > px then d:rect_cw(x, y0 + 3, x + 1, y0 + 3 + ((i % 10 == 0) and tL or tl)) end
      end
    end)
    shape(ass, ACCENT, 0x30, function(d)
      for i = 0, N do
        local x = math.floor(r.x + r.w * i / N)
        if x <= px then d:rect_cw(x, y0 + 3, x + 1, y0 + 3 + ((i % 10 == 0) and tL or tl)) end
      end
    end)
    local k = math.floor(p.u * (hot and 0.28 or 0.22) / 2) * 2
    if style == "f22" then             -- chevron caret riding the tape
      local kk = math.floor(k * 1.3)
      shape(ass, ACCENT, 0x00, function(d) tri(d, px - kk, y0 - kk - 3, px + kk, y0 - kk - 3, px, y0 - 1) end, 1, INK, 0x30)
    else
    shape(ass, ACCENT, 0x00, function(d) d:rect_cw(px - k / 2, y0 - k / 2, px + k / 2, y0 + k / 2) end, 1, INK, 0x20)
    end
    shape(ass, ACCENT, 0x00, function(d) d:rect_cw(px, y0 - math.floor(k * 1.3), px + 1, y0 + 3 + tL) end)
  else                                -- one hairline with a square playhead
    local th = hot and p.st + 1 or p.st
    local y0 = math.floor(cy - th / 2)
    shape(ass, "FFFFFF", 0xA8, function(d) d:rect_cw(r.x, y0, r.x + r.w, y0 + th) end)
    local px = math.floor(r.x + r.w * f)
    if px > r.x then shape(ass, ACCENT, 0x00, function(d) d:rect_cw(r.x, y0, px, y0 + th) end) end
    local k = math.floor(th * (hot and 4.2 or 3.2) / 2) * 2
    shape(ass, ACCENT, 0x00, function(d) d:rect_cw(px - k / 2, cy - k / 2, px + k / 2, cy + k / 2) end,
      1, INK, 0x30)
  end
  state.htag = nil
  if hot and dur and dur > 0 then     -- hover tag: the time under the pointer
    local m = mp.get_property_native("mouse-pos")
    local mx = state.preview_x or (m and m.x)
    if mx then state.htag = { r = r, mx = mx, t = seek_frac(mx) * dur } end   -- drawn last, on top
  end
end

-- neon title ticker ------------------------------------------------------------------------
-- Share Tech Mono (OFL, ~/.local/share/fonts) with a JetBrains Mono fallback. Static when it fits
-- its slot; otherwise it loops right-to-left. The 30 fps timer runs only while the HUD is up and
-- the title overflows.
local NEON = "Share Tech Mono"
local NEON_CORE, NEON_GLOW = "EAFFF6", ACCENT       -- mint-white core, jade glow (BGR)
local SPEED, GAP = 42, "  //  "
local measure_ov = mp.create_osd_overlay("ass-events")
measure_ov.compute_bounds, measure_ov.hidden = true, true
local tw_cache = {}
local marquee = { timer = nil, t0 = mp.get_time(), key = nil, demo = nil }
local function clamp01(v) return math.max(0, math.min(1, v)) end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ["#39"] = "'", ["#x27"] = "'", ["#038"] = "&" }
local function unent(str)                       -- titles arrive with HTML entities (&amp; from X / yt-dlp)
  if not str:find("&", 1, true) then return str end
  return (str:gsub("&(#?%w+);", function(k)
    if ENT[k] then return ENT[k] end
    local n = tonumber(k:match("^#(%d+)$") or "")
    if n and n >= 32 and n < 127 then return string.char(n) end
  end))
end
-- titles: drop emoji + symbols the HUD font can't draw (pictographs, flags, dingbats, variation
-- selectors, ZWJ, keycaps, tags, private use), then tidy the leftover spaces / separators
local function drop_cp(c)
  return c >= 0x1F000                               -- emoji, flags (regional indicators), tags, supplementary symbols
    or (c >= 0x2190 and c <= 0x2BFF)                -- arrows, technical, boxes, shapes, misc symbols, dingbats
    or (c >= 0xFE00 and c <= 0xFE0F) or c == 0x200D or c == 0x20E3 or c == 0xFFFD
    or (c >= 0xE000 and c <= 0xF8FF) or c == 0x3030 or c == 0x303D or (c >= 0x3297 and c <= 0x3299)
    or (c >= 0x2460 and c <= 0x24FF and c ~= 0x24C2)
end
local SEP = { "|", "/", "-", "~", ":", "·", "•", "–", "—", ",", "+" }
local function is_sep(t) for _, x in ipairs(SEP) do if t == x then return true end end return false end
local clean_cache = { k = nil, v = nil, k2 = nil, v2 = nil }
local function clean_title(str)
  if str == clean_cache.k then return clean_cache.v end
  if str == clean_cache.k2 then return clean_cache.v2 end
  local out, n = {}, 0
  if str:find("[\128-\255]") then
    for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local c, b = 0, ch:byte(1)
      if b < 0x80 then c = b
      elseif b < 0xE0 then c = (b % 0x20) * 0x40 + (ch:byte(2) or 0) % 0x40
      elseif b < 0xF0 then c = ((b % 0x10) * 0x40 + (ch:byte(2) or 0) % 0x40) * 0x40 + (ch:byte(3) or 0) % 0x40
      else c = 0x1F000 end                             -- 4-byte = astral plane: treat as emoji (dropped)
      n = n + 1; out[n] = drop_cp(c) and " " or ch
    end
  else out[1] = str end
  local s = table.concat(out):gsub("%s+", " ")
  -- tokens: drop separators that end up doubled or dangling at either end, and empty brackets
  local tok = {}
  for w in s:gmatch("%S+") do
    if is_sep(w) and (#tok == 0 or is_sep(tok[#tok])) then
      -- skip: leading or repeated separator
    else tok[#tok + 1] = w end
  end
  while #tok > 0 and is_sep(tok[#tok]) do tok[#tok] = nil end
  local r = table.concat(tok, " "):gsub("%(%s*%)", ""):gsub("%[%s*%]", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  clean_cache.k2, clean_cache.v2 = clean_cache.k, clean_cache.v
  clean_cache.k, clean_cache.v = str, r
  return r
end
local function tesc(str) return (str:gsub("[{}]", ""):gsub("\\", "/"):gsub("\n", " ")) end
local function text_w(txt, size, w, h)
  local key = size .. "\0" .. txt
  if tw_cache[key] then return tw_cache[key] end
  measure_ov.res_x, measure_ov.res_y = w, h
  measure_ov.data = string.format("{\\q2\\an7\\pos(0,0)\\fn%s\\fs%d\\fsp2\\bord0}%s", NEON, size, txt)
  local r = measure_ov:update()
  local tw = (r and r.x1 and r.x0) and (r.x1 - r.x0) or math.floor(#txt * size * 0.5)
  tw_cache[key] = tw
  return tw
end
local function marquee_run(on)
  if on and not marquee.timer then
    marquee.timer = mp.add_periodic_timer(1 / 25, function() if not remfx.timer then want() end end)
  elseif not on and marquee.timer then
    marquee.timer:kill(); marquee.timer = nil
  end
end
local function neon(ass, x, y, size, txt, an, clip, alpha_k, gcol, ccol)
  local G, Cc = gcol or NEON_GLOW, ccol or NEON_CORE
  local base = string.format("{\\q2\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\fsp2\\shad0%s", an, x, y, NEON, size, clip)
  -- wide soft halo, then a tight glow, then the bright core
  ass:new_event(); ass:append(base .. string.format("\\bord%d\\blur%d\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&}%s",
    math.max(3, math.floor(size * 0.32)), math.max(4, math.floor(size * 0.45)), G, G, a(0x60), a(0x90), txt))
  ass:new_event(); ass:append(base .. string.format("\\bord%d\\blur%d\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&}%s",
    math.max(1, math.floor(size * 0.08)), 2, G, G, a(0x20), a(0x50), txt))
  ass:new_event(); ass:append(base .. string.format("\\bord0\\blur0.4\\1c&H%s&\\1a&H%s&}%s", Cc, a(0x00), txt))
end
-- soft-edged ticker: no hard clip box. The slot fades the text in and out over ~1 em at both
-- ends (4 alpha steps per end, each a \clip slice of the same neon text), and the clip is tall
-- enough that the glow is never cut flat. The font is monospaced, so each slice carries only the
-- characters that can reach it (+ the glow reach): libass renders/blurs, and mpv uploads, a small
-- strip per slice instead of the whole repeated title.
-- exact per-glyph advance of the ticker font at this size (monospaced; libass keeps advances on a
-- 1/64 px grid). Bounds are whole pixels, so the end of a short and a long run of "0" is averaged
-- over 8 sub-pixel phases and the result snapped to 1/64 px: no drift when slices are trimmed.
-- Measured once per size (16 synchronous measure updates), then cached.
local function tick_adv(size, w, h)
  local key = "\1adv" .. size .. "x" .. w
  if tw_cache[key] then return tw_cache[key] end
  local k1 = 4
  local k2 = math.max(k1 + 8, math.min(160, math.floor(w * 0.8 / (size * 0.5 + 2))))
  measure_ov.res_x, measure_ov.res_y = w, h
  local function ends(k)
    local s, run = 0, string.rep("0", k)
    for p = 0, 7 do
      measure_ov.data = string.format("{\\q2\\an7\\pos(%.3f,0)\\fn%s\\fs%d\\fsp2\\bord0}%s", 4 + p / 8, NEON, size, run)
      local r = measure_ov:update()
      if not (r and r.x1) then return nil end
      s = s + r.x1 - p / 8
    end
    return s / 8
  end
  local e1, e2 = ends(k1), ends(k2)
  local adv = (e1 and e2) and (e2 - e1) / (k2 - k1) or (size * 0.461 + 2)
  local q = math.floor(adv * 64 + 0.5) / 64
  if math.abs(adv - q) < 0.004 then adv = q end
  tw_cache[key] = adv
  return adv
end
local function soft_ticker(ass, x, T, txt, tw1, n1, w, h)
  local size = T.fs
  local hb, hbl = math.max(3, math.floor(size * 0.32)), math.max(4, math.floor(size * 0.45))
  local reach = hb + 2 * hbl                                   -- glow reach past a glyph
  local ty0, ty1 = T.cy - math.floor(size * 0.5) - reach, T.cy + math.floor(size * 0.5) + reach
  local F, K = math.max(10, math.floor(size * 1.0)), 4
  local slot = T.x1 - T.x0
  if slot < 2 * F + 4 then F = math.floor(slot / 3) end
  local adv = tick_adv(size, w, h)
  -- trim only when the advance is uniform (ASCII title in the mono font); else full text per slice
  local mono = not txt:find("[\128-\255\\{}]") and math.abs(adv * n1 - tw1) < adv * 0.9
  local function slice(sx0, sx1, m)
    if sx1 <= sx0 then return end
    local s, px = txt, x
    if mono then
      local i0 = math.max(0, math.floor((sx0 - reach - x) / adv) - 1)
      local i1 = math.min(#txt, math.ceil((sx1 + reach - x) / adv) + 1)
      if i1 <= i0 then return end
      s, px = txt:sub(i0 + 1, i1), x + i0 * adv
    end
    local function al(v) return string.format("%02X", 255 - math.floor((255 - tonumber(a(v), 16)) * m + 0.5)) end
    local base = string.format("{\\q2\\an4\\pos(%.3f,%d)\\fn%s\\fs%d\\fsp2\\shad0\\clip(%d,%d,%d,%d)", px, T.cy, NEON, size,
      math.floor(sx0), ty0, math.floor(sx1), ty1)
    ass:new_event(); ass:append(base .. string.format("\\bord%d\\blur%d\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&}%s",
      hb, hbl, NEON_GLOW, NEON_GLOW, al(0x60), al(0x90), s))
    ass:new_event(); ass:append(base .. string.format("\\bord%d\\blur%d\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&}%s",
      math.max(1, math.floor(size * 0.08)), 2, NEON_GLOW, NEON_GLOW, al(0x20), al(0x50), s))
    ass:new_event(); ass:append(base .. string.format("\\bord0\\blur0.4\\1c&H%s&\\1a&H%s&}%s", NEON_CORE, al(0x00), s))
  end
  local step = F / K
  for i = 1, K do
    local m = i / (K + 1)
    slice(T.x0 + (i - 1) * step, T.x0 + i * step, m)               -- left fade-in
    slice(T.x1 - i * step, T.x1 - (i - 1) * step, m)               -- right fade-out
  end
  slice(T.x0 + F, T.x1 - F, 1)
end
local function draw_title(ass, p, w, h)
  local T = p.title
  local raw = marquee.demo or mp.get_property("media-title") or ""
  if not T or raw == "" then marquee_run(false); return end
  local txt = tesc(clean_title(unent(raw)))
  if txt == "" then marquee_run(false); return end    -- title was only emoji
  local slot = T.x1 - T.x0
  local tw = text_w(txt, T.fs, w, h)
  if hud.light then                                       -- LIGHT: static title, cut with an ellipsis, no timer
    marquee_run(false)
    local key = txt .. "\0" .. slot .. "\0" .. T.fs
    if hud.tkey ~= key then
      local out = txt
      if tw > slot then
        local n = math.max(1, math.floor(#txt * slot / tw))
        repeat
          local c = n
          while c > 1 and (txt:byte(c + 1) or 0) >= 0x80 and (txt:byte(c + 1) or 0) < 0xC0 do c = c - 1 end
          out = txt:sub(1, c):gsub("%s+$", "") .. "…"
          n = c - 1
        until n < 1 or text_w(out, T.fs, w, h) <= slot
      end
      hud.tkey, hud.tout = key, out
    end
    mtext(ass, math.floor((T.x0 + T.x1) / 2), T.cy, T.fs, ACCENT, 0x00, hud.tout, 5, "\\fsp1")
    return
  end
  -- (no slot brackets / hard clip box: the ends fade softly, see soft_ticker)
  -- continuous ticker: always scrolls (even when the title fits), seamless loop "title  //  title  //"
  if marquee.key ~= txt then marquee.key = txt; marquee.t0 = mp.get_time() end
  local loop = txt .. GAP
  local lw = math.max(1, text_w(loop, T.fs, w, h))
  local reps = math.floor(slot / lw) + 2                  -- enough copies to cover the slot + one wrap
  local off = ((mp.get_time() - marquee.t0) * SPEED) % lw
  local x = math.floor(T.x0 - off)
  soft_ticker(ass, x, T, string.rep(loop, reps), tw, #txt, w, h)
  marquee_run(state.visible)
end

-- f22 cockpit instruments ------------------------------------------------------------------
-- Every element is a control or a live readout (no decoration-only tiles):
--   nav data line: CH (window corner from the launcher, else socket number), RES video-params/h,
--   FPS container-fps, CODEC video-format, local clock; VOL gauge = volume (click / drag);
--   SPD softkey = speed cycle; LOOP softkey = loop-file; LINK lamp = demuxer-cache-duration,
--   amber while paused-for-cache / cache < 2 s, grey for local files.
local chan_cache = { t = -10, v = "--" }
local function channel()
  if mp.get_time() - chan_cache.t < 2 then return chan_cache.v end
  local sock = mp.get_property("input-ipc-server") or ""
  local v
  local fh = sock ~= "" and io.open((sock:gsub("%.sock$", "")) .. ".corner", "r")
  if fh then v = (fh:read("*l") or ""):upper():gsub("[^%w]", ""); fh:close() end
  if not v or v == "" then
    local n = sock:match("%-(%d+)%.sock$")
    v = n and #n <= 3 and string.format("%02d", tonumber(n)) or "01"
  end
  chan_cache.t, chan_cache.v = mp.get_time(), v
  return v
end
local SPEEDS = { 1, 1.25, 1.5, 2, 0.75 }
local info_pop                     -- (set further down) centre popup for SPD / LOOP / BUFFER
local set_light                    -- (set further down) HUD COMBAT / CRUISE
local arm_toggle                   -- (set further down) MASTER ARM / STAND DOWN panel
local function link_state()
  if not mp.get_property_bool("demuxer-via-network") then return "LOCAL", "FFFFFF", 0x80 end
  local c = mp.get_property_number("demuxer-cache-duration") or 0
  local txt = string.format("LINK %02ds", math.min(99, math.floor(c)))
  if mp.get_property_bool("paused-for-cache") or (c < 2 and not mp.get_property_bool("demuxer-cache-idle")) then
    return txt, AMBER, 0x00
  end
  return txt, ACCENT, 0x00
end
-- fullscreen cockpit: screen frame, heading (fine-seek) tape, VOL + TIME vertical tapes ----------
local function lbl_t(t, long)
  t = math.floor(t + 0.5)
  if long then return string.format("%d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60) end
  return string.format("%02d:%02d", math.floor(t / 60), t % 60)
end
local function ptr_box(ass, x, y, side_, txt, size, col, bw, bh, mode, tcol)   -- tcol: readout colour (default white)
  -- boxed readout with a pointer notch: side_ = 1 notch on the left (box to the right), -1 mirrored
  -- mode: nil normal | "hot" (hover / drag: thicker frame + up/down chevrons) | "ghost" (value under the cursor)
  local x0 = side_ > 0 and x + math.floor(bh * 0.35) or x - math.floor(bh * 0.35) - bw
  local ghost = mode == "ghost"
  shape(ass, INK, ghost and 0x60 or 0x18, function(d) d:rect_cw(x0, y - bh / 2, x0 + bw, y + bh / 2) end)
  shape(ass, col, ghost and 0x90 or 0x00, function(d)
    outline(d, x0, math.floor(y - bh / 2), bw, bh, mode == "hot" and 3 or (ghost and 1 or 2))
    local k = math.floor(bh * 0.35)
    if side_ > 0 then tri(d, x0, y - k, x0, y + k, x0 - k, y) else tri(d, x0 + bw, y - k, x0 + bw, y + k, x0 + bw + k, y) end
  end)
  if mode == "hot" then                              -- drag affordance: chevrons above and below the box
    local cx, k, gp = math.floor(x0 + bw / 2), math.floor(bh * 0.32), math.floor(bh * 0.18)
    local yt, yb = math.floor(y - bh / 2) - gp, math.floor(y + bh / 2) + gp
    shape(ass, col, 0x00, function(d)
      tri(d, cx - k, yt, cx + k, yt, cx, yt - k)
      tri(d, cx - k, yb, cx, yb + k, cx + k, yb)
    end)
  end
  mtext(ass, x0 + bw / 2, y, size, tcol or "FFFFFF", ghost and 0x70 or 0x00, txt, 5, "\\fsp1")
  return x0
end
function remfx.cur(pos)       -- time-pos interpolated between frames while playing
  local cur = remfx.pos or pos or 0
  if not mp.get_property_bool("pause") and remfx.pos then
    local fps = mp.get_property_number("container-fps") or 30
    cur = cur + math.min(mp.get_time() - remfx.at, 1 / math.max(fps, 1)) * (mp.get_property_number("speed") or 1)
  end
  return cur
end
-- "07:59" .. small ".482": returns ASS text + its visible length (milliseconds smaller, optionally dimmer)
local function tms(t, size, dim, prefix)
  t = math.max(0, t or 0)
  local i = math.floor(t)
  local main = i >= 3600 and string.format("%d:%02d:%02d", math.floor(i / 3600), math.floor(i / 60) % 60, i % 60)
    or string.format("%02d:%02d", math.floor(i / 60), i % 60)
  main = (prefix or "") .. main
  local ms = string.format(".%03d", math.min(999, math.floor((t - i) * 1000)))
  local small = math.floor(size * 0.72 + 0.5)
  return main .. string.format("{\\fs%d%s}", small, dim and ("\\1a&H" .. a(dim) .. "&") or "") .. ms,
    #main + 4 * 0.72
end
remfx.tms = tms
-- END RAMP: end-of-video escalation. Each threshold = min(abs seconds, pct x duration) remaining, so a
-- long video warns at 4:00 / 2:00 / 1:00 / 0:30 with the NEXT card at 0:15, and a short clip scales
-- down (20 s clip: amber 6 s, red 3 s, NEXT 2 s; never red near its start). One eased breath per
-- `period` s (cosine, never off: the red only dims to 1 - depth); the last stage is the calmest-fast
-- (1.0 s), slower than the old 2 Hz hard blink. COMBAT breathes on the existing 25 Hz REM clock;
-- CRUISE (2 Hz tick) shows the stage colour steady, no breath. No new timers.
remfx.ramp = {
  amber  = { 240, 0.30 },                                  -- caution: steady amber        {abs s, pct}
  stages = { { 120, 0.15 }, { 60, 0.08 }, { 30, 0.04 } },  -- S1 WARN / S2 / S3: red, breathing
  next   = { 15, 0.10, 2 },                                -- FINAL: NEXT card (+ floor 2 s)
  period = { 2.4, 1.8, 1.3, 1.0 },                         -- breath length per stage (s)
  depth  = { 0.30, 0.40, 0.50, 0.55 },                     -- how far the red dims mid-breath
}
function remfx.nexti()                                     -- playlist index of a real next item, or nil
  local lp = mp.get_property("loop-file", "no")
  if lp ~= "no" and lp ~= "0" then return nil end          -- REPEAT on: the same video again, no NEXT
  local n, cnt = mp.get_property_number("playlist-pos", 0), mp.get_property_number("playlist-count", 1)
  if n + 1 < cnt then return n + 1 end
  if cnt > 1 and mp.get_property("loop-playlist", "no") ~= "no" then return 0 end
  return nil
end
function remfx.ramp_t(e, dur) return math.max(e[3] or 0, math.min(e[1], e[2] * dur)) end
function remfx.dimc(hex, k)                                -- BGR hex scaled toward black by k (0..1)
  local o = {}
  for i = 1, 5, 2 do o[#o + 1] = string.format("%02X", math.floor(tonumber(hex:sub(i, i + 1), 16) * k + 0.5)) end
  return table.concat(o)
end
function remfx.mix(a, b, k)                                -- BGR hex blend a -> b by k (0..1)
  local o = {}
  for i = 1, 5, 2 do
    local x, y = tonumber(a:sub(i, i + 1), 16), tonumber(b:sub(i, i + 1), 16)
    o[#o + 1] = string.format("%02X", math.floor(x + (y - x) * k + 0.5))
  end
  return table.concat(o)
end
-- TOP timer (heading-tape time box + lubber/caret): rides the END RAMP stages, no timer of its own.
-- jade -> (caution zone + S1) steady amber -> (S2/S3) amber<->rust eased pulse on the REM breath
-- phase -> (FINAL) rust breathing at the final period. Paused: remfx.ph stops, so the colour holds.
function remfx.tcol(pos, dur)
  if not dur or dur <= 0 or is_live() then return ACCENT end
  local _, c = remfx.state(pos, dur)
  local st = c.stage
  if st == 0 then return c.scol == AMBER and AMBER or ACCENT end
  if st == 1 then return AMBER end
  local wv = 0.5 - 0.5 * math.cos((remfx.ph or 0) * 2 * math.pi)   -- 0 = REM bright, 1 = REM dim
  if st >= 4 then return remfx.dimc(RUST, 1 - remfx.ramp.depth[4] * 0.6 * wv) end
  local lo, hi = (st == 2) and 0 or 0.4, (st == 2) and 0.6 or 1
  return remfx.mix(AMBER, RUST, lo + (hi - lo) * wv)
end
function remfx.state(pos, dur)
  local paused = mp.get_property_bool("pause")
  dur = dur or 0
  local cur = remfx.cur(pos)
  local rem = math.max(0, dur - cur)
  local R = remfx.ramp
  local c = { label = "REM", rem = rem, stage = 0 }
  if dur > 0 then
    for i, e in ipairs(R.stages) do if rem <= remfx.ramp_t(e, dur) then c.stage = math.max(c.stage, i) end end
    c.nextwin = rem <= remfx.ramp_t(R.next, dur)
    if c.nextwin then c.stage = 4 end
  end
  if c.stage > 0 then
    c.vcol, c.ocol, c.othick, c.scol = ALERT, ALERT, c.stage >= 4 and 3 or 2, ALERT
    if not paused and not hud.light then                   -- eased breath (COMBAT only, while playing)
      local now = mp.get_time()
      local dt = math.min(0.2, math.max(0, now - (remfx.pt or now))); remfx.pt = now
      remfx.ph = ((remfx.ph or 0) + dt / R.period[c.stage]) % 1   -- phase carries over stage changes: no jumps
      local k = 1 - R.depth[c.stage] * (0.5 - 0.5 * math.cos(remfx.ph * 2 * math.pi))
      c.vcol = remfx.dimc(ALERT, k); c.ocol = c.vcol
    end
  elseif dur > 0 and rem <= remfx.ramp_t(R.amber, dur) then c.vcol, c.ocol, c.othick, c.scol = AMBER, AMBER, 2, AMBER
  else c.vcol, c.scol = ACCENT, ACCENT end
  local fn, fc = mp.get_property_number("estimated-frame-number"), mp.get_property_number("estimated-frame-count")
  if fn then c.frm = string.format("FRM %06d", fn) .. (fc and string.format("/%06d", fc) or "") end
  return rem, c
end
function remfx.sync()   -- 25 Hz only while the f22 HUD is visible and playing; LIVE fullscreen tape: 10 Hz scroll
  local base = state.visible and style == "f22" and not hud.light and not mp.get_property_bool("pause")
  local lv = base and is_live()
  local rate = lv and (mp.get_property_bool("fullscreen") and 0.1 or nil)
    or ((base and (mp.get_property_number("duration") or 0) > 0) and 1 / 25 or nil)
  if remfx.timer and remfx.rate ~= rate then remfx.timer:kill(); remfx.timer = nil end
  if rate and not remfx.timer then remfx.timer = mp.add_periodic_timer(rate, want) end
  remfx.rate = rate
end
local function draw_fs(ass, p, b, w, h, pos, dur)
  local u, fs, lf = p.u, p.fs, p.lf or math.floor(p.fs * 0.7)
  -- 1. screen frame: hairline + jade corner brackets, inside the safe margin
  local mx, my = math.floor(p.side * 0.45), math.floor(p.bottom * 0.45)
  local L = math.floor(u * 1.6)
  shape(ass, "FFFFFF", 0xD8, function(d) outline(d, mx, my, w - 2 * mx, h - 2 * my, 1) end)
  shape(ass, ACCENT, 0x10, function(d)
    for _, c in ipairs({ { mx, my, 1, 1 }, { w - mx, my, -1, 1 }, { mx, h - my, 1, -1 }, { w - mx, h - my, -1, -1 } }) do
      local x, y, sx, sy = c[1], c[2], c[3], c[4]
      d:rect_cw(math.min(x, x + sx * L), math.min(y, y + sy * 2), math.max(x, x + sx * L), math.max(y, y + sy * 2))
      d:rect_cw(math.min(x, x + sx * 2), math.min(y, y + sy * L), math.max(x, x + sx * 2), math.max(y, y + sy * L))
    end
  end)
  local LV = is_live()
  if (not dur or dur <= 0) and not LV then return end
  pos = pos or 0
  if LV then remfx.live_dur = dur; if not dur or dur <= 0 then dur = math.max(pos, 1) end end   -- LIVE: tapes end at "now"
  local long = dur >= 3600
  -- 2. heading tape: +/- 60 s around now, click = seek there
  local r = b.htape
  if r then
    local span = 120
    local pxs = r.w / span; r.pxs = pxs
    local cx, base = r.x + r.w / 2, r.y + r.h - 2
    local hot = state.hot == "htape"
    shape(ass, INK, 0x90, function(d) d:rect_cw(r.x - lf, r.y, r.x + r.w + lf, base + 2) end)
    shape(ass, "FFFFFF", hot and 0x70 or 0xA0, function(d) d:rect_cw(r.x, base, r.x + r.w, base + 1) end)
    local t0 = math.ceil((pos - span / 2) / 5) * 5
    local past, ahead = {}, {}
    for t = t0, pos + span / 2, 5 do
      if t >= 0 and t <= dur then
        local x = math.floor(cx + (t - pos) * pxs)
        local len = (t % 30 == 0) and math.floor(r.h * 0.42) or ((t % 15 == 0) and math.floor(r.h * 0.28) or math.floor(r.h * 0.16))
        local list = t <= pos and past or ahead
        list[#list + 1] = { x, len }
        if t % 30 == 0 and math.abs(x - cx) > lf * 3 then
          mtext(ass, x, base - len - math.floor(lf * 0.3), lf, t <= pos and ACCENT or "FFFFFF", t <= pos and 0x10 or 0x50, lbl_t(t, long), 2, "\\fsp0")
        end
      end
    end
    shape(ass, "FFFFFF", 0x70, function(d) for _, k in ipairs(ahead) do d:rect_cw(k[1], base - k[2], k[1] + 2, base) end end)
    if #past > 0 then shape(ass, ACCENT, 0x20, function(d) for _, k in ipairs(past) do d:rect_cw(k[1], base - k[2], k[1] + 2, base) end end) end
    -- centre lubber line + caret + boxed now (colour follows the END RAMP: remfx.tcol)
    local k = math.floor(u * 0.22)
    local TC = remfx.tcol(pos, dur)
    shape(ass, TC, 0x00, function(d)
      d:rect_cw(cx - 1, r.y, cx + 1, base + 2)
      tri(d, cx - k, base + 2 + k, cx + k, base + 2 + k, cx, base + 3)
    end)
    local bw, bh = math.floor(fs * 6.2), math.floor(fs * 1.5)
    shape(ass, INK, 0x20, function(d) d:rect_cw(cx - bw / 2, base + 4 + k, cx + bw / 2, base + 4 + k + bh) end)
    shape(ass, TC, 0x00, function(d) outline(d, math.floor(cx - bw / 2), base + 4 + k, bw, bh, 2) end)
    mtext(ass, cx, base + 4 + k + bh / 2, math.floor(fs * 1.05), "FFFFFF", 0x00, (tms(remfx.cur(pos), math.floor(fs * 1.05), 0x50)), 5, "\\fsp1")
    mtext(ass, r.x, base + 4 + k + bh / 2, lf, "FFFFFF", 0x70, "-60s", 4, "\\fsp2")
    mtext(ass, r.x + r.w, base + 4 + k + bh / 2, lf, "FFFFFF", 0x70, "+60s", 6, "\\fsp2")
  end
  -- 3. VOL tape (left, airspeed style): drag / click sets volume
  local vr = b.vtape
  if vr then
    local vol, muted = mp.get_property_number("volume") or 0, mp.get_property_bool("mute")
    local VC = muted and RUST or ACCENT
    local HI = 80                                        -- upper zone 80-100: muted amber, like a gauge's caution arc
    local PC = muted and RUST or (vol > HI and AMBER or ACCENT)   -- pointer box: amber above 80 (rust stays mute)
    local bx = vr.x + vr.w                               -- baseline on the inner edge
    local y1, y0 = vr.y + vr.h, vr.y
    local function vy(v) return math.floor(y1 - math.max(0, math.min(100, v)) / 100 * vr.h) end
    shape(ass, INK, 0x90, function(d) d:rect_cw(vr.x - math.floor(lf * 0.6), y0 - math.floor(fs * 1.7), bx + 1, y1 + math.floor(fs * 1.8)) end)
    local vhot = state.hot == "vtape" or state.vdrag == "vtape"
    if vhot and vr.grab then                         -- hover: the whole grab area lights up (corner brackets)
      local gr = vr.grab
      shape(ass, ACCENT, 0x70, function(d) outline(d, gr.x, gr.y, gr.w, gr.h, 1) end)
      shape(ass, ACCENT, 0x10, function(d) ticks(d, gr.x, gr.y, gr.w, gr.h, 2, math.floor(fs * 0.8)) end)
    end
    shape(ass, vhot and ACCENT or "FFFFFF", vhot and 0x00 or 0x90, function(d) d:rect_cw(bx - (vhot and 2 or 1), y0, bx, y1) end)
    local function vticks(lo, hi) return function(d)
      for v = lo, hi, 5 do
        local len = (v % 10 == 0) and math.floor(vr.w * 0.5) or math.floor(vr.w * 0.25)
        local y = vy(v); d:rect_cw(bx - len, y, bx, y + 2)
      end
    end end
    shape(ass, "FFFFFF", 0x70, vticks(0, HI - 5))
    shape(ass, AMBER, 0x30, function(d)                  -- caution zone: amber ticks + thin band on the column edge
      vticks(HI, 100)(d); d:rect_cw(bx - 2, vy(100), bx, vy(HI))
    end)
    if muted then
      shape(ass, VC, 0x40, function(d) d:rect_cw(bx - 4, vy(vol), bx, y1) end)
    else
      shape(ass, ACCENT, 0x00, function(d) d:rect_cw(bx - 4, math.max(vy(vol), vy(HI)), bx, y1) end)
      if vol > HI then shape(ass, AMBER, 0x00, function(d) d:rect_cw(bx - 4, vy(vol), bx, vy(HI)) end) end
    end
    for v = 0, 100, 20 do
      local hz = v >= HI
      mtext(ass, bx - math.floor(vr.w * 0.6), vy(v), lf, hz and AMBER or "FFFFFF", hz and 0x10 or 0x50, tostring(v), 6, "\\fsp0")
    end
    mtext(ass, vr.x, y0 - math.floor(fs * 1.0), math.floor(fs * 0.85), VC, 0x00, "VOL", 4, "\\fsp3")
    mtext(ass, vr.x, y1 + math.floor(fs * 1.1), lf, muted and RUST or "FFFFFF", muted and 0x00 or 0x60, muted and "MUTED" or "AUDIO", 4, "\\fsp2")
    local pbh = math.floor(fs * 1.6)
    if vhot and not state.vdrag and state.my and math.abs(state.my - vy(vol)) > pbh * 0.6 then   -- ghost: value under the cursor
      local gy = math.max(y0, math.min(y1, state.my))
      shape(ass, ACCENT, 0x50, function(d) d:rect_cw(vr.x, gy - 1, bx, gy + 1) end)
      ptr_box(ass, bx + 2, gy, 1, string.format("%03d", math.floor(clamp01((y1 - gy) / vr.h) * 100 + 0.5)),
        math.floor(fs * 1.0), ACCENT, math.floor(fs * 3.0), math.floor(fs * 1.3), "ghost")
    end
    ptr_box(ass, bx + 2, vy(vol), 1, muted and "MUT" or string.format("%03d", math.floor(vol + 0.5)),
      math.floor(fs * 1.15), PC, math.floor(fs * 3.0), pbh, vhot and "hot" or nil, PC == AMBER and AMBER or nil)
  end
  -- 4. REM tape (right, altitude style): COUNTDOWN. Remaining time is the altitude: the pointer
  -- descends to T-00:00 at the bottom; labels are remaining time. Drag / click seeks to dur - rem.
  local tr = b.ttape
  if tr and LV then   -- LIVE tape: no end, no countdown. Watch time climbs (tape scrolls down, 5 s
    -- ticks), the ON AIR index box reads elapsed watch time, the foot reads how far behind the live
    -- edge you are (DVR streams) or the buffer. Click = jump to the live edge.
    local bx, y0, y1 = tr.x, tr.y, tr.y + tr.h
    local thot = state.hot == "ttape"
    local abs = remfx.cur(pos)
    local pth = mp.get_property("path") or ""
    if live.p0k ~= pth then live.p0k, live.p0 = pth, abs end      -- watch time counts from where you joined
    local cur = math.max(0, abs - (live.p0 or abs))
    local span = math.max(60, math.floor(tr.h / (fs * 0.5)))          -- seconds shown over the column
    local ny = y0 + math.floor(tr.h * 0.35)                            -- "now" index: a third of future above
    local pps = tr.h / span
    local paused = mp.get_property_bool("pause")
    local LC = paused and AMBER or ACCENT
    if thot and tr.grab then
      local gr = tr.grab
      shape(ass, ACCENT, 0x70, function(d) outline(d, gr.x, gr.y, gr.w, gr.h, 1) end)
    end
    shape(ass, INK, 0x90, function(d) d:rect_cw(bx, y0 - math.floor(fs * 1.7), tr.x + tr.w + math.floor(lf * 0.6), y1 + math.floor(fs * 1.8)) end)
    shape(ass, thot and ACCENT or "FFFFFF", thot and 0x00 or 0x90, function(d) d:rect_cw(bx, y0, bx + (thot and 2 or 1), y1) end)
    local past, ahead = {}, {}
    local tlo, thi = cur - (y1 - ny) / pps, cur + (ny - y0) / pps
    for t = math.ceil(tlo / 5) * 5, thi, 5 do
      if t >= 0 then
        local y = math.floor(ny + (cur - t) * pps)
        local isM = t % 30 == 0
        local len = isM and math.floor(tr.w * 0.5) or math.floor(tr.w * 0.25)
        local list = t <= cur and past or ahead
        list[#list + 1] = { y, len }
        if isM and t <= cur and math.abs(y - ny) > fs * 1.2 then
          mtext(ass, bx + math.floor(tr.w * 0.6), y, lf, ACCENT, 0x10, lbl_t(t, cur >= 3600), 4, "\\fsp0")
        end
      end
    end
    if #ahead > 0 then shape(ass, "FFFFFF", 0xB0, function(d) for _, k in ipairs(ahead) do d:rect_cw(bx, k[1], bx + k[2], k[1] + 2) end end) end
    if #past > 0 then shape(ass, ACCENT, 0x20, function(d) for _, k in ipairs(past) do d:rect_cw(bx, k[1], bx + k[2], k[1] + 2) end end) end
    shape(ass, LC, 0x00, function(d) d:rect_cw(bx, ny, bx + 4, y1) end)                 -- watched bar
    shape(ass, ALERT, paused and 0x60 or 0x00, function(d) d:rect_cw(tr.x + tr.w - math.floor(fs * 4.6), y0 - math.floor(fs * 1.35),
      tr.x + tr.w - math.floor(fs * 4.0), y0 - math.floor(fs * 0.75)) end)            -- square ON AIR lamp
    mtext(ass, tr.x + tr.w, y0 - math.floor(fs * 1.0), math.floor(fs * 0.85), LC, 0x00, paused and "HOLD" or "LIVE", 6, "\\fsp3")
    local ld = remfx.live_dur
    local foot, boxt
    if ld and ld > 0 then                                              -- DVR stream: box = behind the live edge
      boxt = tms(math.max(0, ld - abs), math.floor(fs * 1.15), 0x50, "-")
      foot = "WATCH " .. dtime(cur)
    else                                                               -- no DVR: box = watch time
      boxt = tms(cur, math.floor(fs * 1.15), 0x50, "+")
      foot = string.format("BUF %02ds", math.floor(mp.get_property_number("demuxer-cache-duration") or 0))
    end
    mtext(ass, tr.x + tr.w, y1 + math.floor(fs * 1.1), lf, "FFFFFF", 0x60, foot, 6, "\\fsp2")
    ptr_box(ass, bx - 2, ny, -1, boxt, math.floor(fs * 1.15), LC,
      math.floor(fs * 6.6), math.floor(fs * 1.6), thot and "hot" or nil)
  elseif tr then
    local bx = tr.x
    local y1, y0 = tr.y + tr.h, tr.y
    local function ry_(rem) return math.floor(y1 - math.max(0, math.min(1, rem / dur)) * tr.h) end
    local thot = state.hot == "ttape" or state.vdrag == "ttape"
    local cur = (state.vdrag == "ttape" and state.seek_tgt) or remfx.cur(pos)
    local rem = math.max(0, dur - cur)
    local _, cd = remfx.state(pos, dur)
    local RC, RS = cd.vcol or ACCENT, cd.scol or cd.vcol or ACCENT   -- RC breathes, RS steady
    if thot and tr.grab then
      local gr = tr.grab
      shape(ass, ACCENT, 0x70, function(d) outline(d, gr.x, gr.y, gr.w, gr.h, 1) end)
      shape(ass, ACCENT, 0x10, function(d) ticks(d, gr.x, gr.y, gr.w, gr.h, 2, math.floor(fs * 0.8)) end)
    end
    shape(ass, INK, 0x90, function(d) d:rect_cw(bx, y0 - math.floor(fs * 1.7), tr.x + tr.w + math.floor(lf * 0.6), y1 + math.floor(fs * 1.8)) end)
    shape(ass, thot and ACCENT or "FFFFFF", thot and 0x00 or 0x90, function(d) d:rect_cw(bx, y0, bx + (thot and 2 or 1), y1) end)
    local NICE = { 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18000 }
    local M = NICE[#NICE]
    for _, v in ipairs(NICE) do if (dur / v) * fs * 2.4 <= tr.h then M = v; break end end
    local sub = M / 2
    local left, gone = {}, {}                         -- marks still ahead (<= rem) / already flown (> rem)
    for r = 0, dur, sub do
      local isM = (r / M) == math.floor(r / M)
      local len = isM and math.floor(tr.w * 0.5) or math.floor(tr.w * 0.25)
      local list = r <= rem and left or gone
      list[#list + 1] = { ry_(r), len }
      if isM then mtext(ass, bx + math.floor(tr.w * 0.6), ry_(r), lf, r <= rem and RS or "FFFFFF", r <= rem and 0x10 or 0x70,
        (r == 0 and "T-0" or lbl_t(r, long)), 4, "\\fsp0") end
    end
    if #gone > 0 then shape(ass, "FFFFFF", 0xA0, function(d) for _, k in ipairs(gone) do d:rect_cw(bx, k[1], bx + k[2], k[1] + 2) end end) end
    if #left > 0 then shape(ass, RS, 0x20, function(d) for _, k in ipairs(left) do d:rect_cw(bx, k[1], bx + k[2], k[1] + 2) end end) end
    shape(ass, RS, 0x00, function(d) d:rect_cw(bx, ry_(rem), bx + 4, y1) end)          -- remaining "fuel" bar
    mtext(ass, tr.x + tr.w, y0 - math.floor(fs * 1.0), math.floor(fs * 0.85), RC, 0x00, "REM T-", 6, "\\fsp3")
    mtext(ass, tr.x + tr.w, y1 + math.floor(fs * 1.1), lf, "FFFFFF", 0x60, "DUR " .. dtime(dur), 6, "\\fsp2")
    local pbh = math.floor(fs * 1.6)
    if thot and not state.vdrag and state.my and math.abs(state.my - ry_(rem)) > pbh * 0.6 then
      local gy = math.max(y0, math.min(y1, state.my))
      local grem = clamp01((y1 - gy) / tr.h) * dur
      shape(ass, ACCENT, 0x50, function(d) d:rect_cw(bx, gy - 1, tr.x + tr.w, gy + 1) end)
      ptr_box(ass, bx - 2, gy, -1, (tms(grem, math.floor(fs * 1.0), 0x50, "T-")), math.floor(fs * 1.0), ACCENT,
        math.floor(fs * 6.6), math.floor(fs * 1.3), "ghost")
    end
    ptr_box(ass, bx - 2, ry_(rem), -1, (tms(rem, math.floor(fs * 1.15), 0x50, "T-")), math.floor(fs * 1.15), RC,
      math.floor(fs * 6.6), pbh, thot and "hot" or nil)
  end
end
local function draw_fpm(ass, w, h, u, FS)        -- targeting scope: play / pause acknowledgement
  if idle_empty_now() then return end               -- no scope on the empty window
  local paused = mp.get_property_bool("pause")
  local e = fpm.freeze or (mp.get_time() - fpm.t)   -- (freeze: preview hook for screenshots)
  local HOLD, FADE = 2.0, 0.6
  if not paused and e > HOLD + FADE then return end
  if paused and not fpm.paused then return end      -- (pause flash not armed yet: nothing)
  -- PAUSED: 2 crisp crosshair blinks (150 ms on / off), then the WHOLE scope group (brackets, cross,
  -- rings, pips, labels) eases to ~56 % opacity over 0.3 s and holds steady until play; no pause
  -- timer after that (the 2.7 s flash timer covers it). PLAY: unchanged full brightness + fade.
  local BL, NB = 0.15, 2
  local BLINK, DIM = 2 * BL * NB, 0x70
  local al
  if paused then al = e <= BLINK and 0 or math.floor(DIM * math.min(1, (e - BLINK) / 0.3))
  elseif e <= HOLD then al = 0
  else al = math.floor(255 * math.min(1, (e - HOLD) / FADE)) end
  local function A(x)
    if paused then return math.floor(255 - (255 - math.min(255, x)) * (255 - al) / 255) end   -- scale opacity
    return math.min(255, al + x)
  end
  local function SA(x) return math.floor(255 - (255 - x) * (255 - al) / 255) end   -- shadow: fades with the scope
  local cx, cy = math.floor(w / 2), math.floor(h / 2)
  local S = math.floor(h * (FS and 0.19 or 0.21))   -- FS: 83 % of the old 0.23
  local T = math.max(3, math.floor(S * 0.022))
  local k = math.min(1, e / 0.2); k = 1 - (1 - k) ^ 3            -- 200 ms snap-in (ease-out)
  local R = math.floor(S / 2 * (1 + 0.7 * (1 - k)))
  local L = math.floor(S * 0.22)
  local function sh(col, alpha, blur, fn)
    ass:new_event()
    ass:append(string.format("{\\an7\\pos(0,0)\\shad0\\bord0\\blur%d\\1c&H%s&\\1a&H%02X&}", blur, col, math.min(255, alpha)))
    ass:draw_start(); fn(ass); ass:draw_stop()
  end
  local function geom(d)
    local t = math.floor(T * 1.4)
    for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do          -- lock brackets
      local x, y = cx + c[1] * R, cy + c[2] * R
      local xa, xb = math.min(x, x - c[1] * L), math.max(x, x - c[1] * L)
      local ya, yb = math.min(y, y - c[2] * L), math.max(y, y - c[2] * L)
      d:rect_cw(xa, math.min(y, y - c[2] * t), xb, math.max(y, y - c[2] * t))
      d:rect_cw(math.min(x, x - c[1] * t), ya, math.max(x, x - c[1] * t), yb)
    end
  end
  local function cross(d)                                                     -- crosshair with gaps + square dot
    local g0, g1 = math.floor(S * 0.11), math.floor(S * 0.42)
    d:rect_cw(cx - g1, cy - T / 2, cx - g0, cy + T / 2); d:rect_cw(cx + g0, cy - T / 2, cx + g1, cy + T / 2)
    d:rect_cw(cx - T / 2, cy - g1, cx + T / 2, cy - g0); d:rect_cw(cx - T / 2, cy + g0, cx + T / 2, cy + g1)
    for i = 1, 5 do                                                           -- tick marks on the arms (same state colour)
      local o = math.floor(S * (0.11 + i * 0.06))
      local len = (i % 2 == 0) and math.floor(S * 0.05) or math.floor(S * 0.028)
      local tt = math.max(2, math.floor(T * 0.6))
      d:rect_cw(cx - o, cy + T / 2, cx - o + tt, cy + T / 2 + len); d:rect_cw(cx + o - tt, cy + T / 2, cx + o, cy + T / 2 + len)
      d:rect_cw(cx + T / 2, cy - o, cx + T / 2 + len, cy - o + tt); d:rect_cw(cx + T / 2, cy + o - tt, cx + T / 2 + len, cy + o)
    end
    local q = math.max(2, math.floor(S * 0.022))
    d:rect_cw(cx - q, cy - q, cx + q, cy + q)
  end
  -- lock-on rings OUTSIDE the brackets: 1 solid + 2 broken. PLAY: contract + counter-rotate, snap red at lock
  local LOCK = 0.6
  local kk = paused and 1 or math.min(1, e / LOCK); kk = 1 - (1 - kk) ^ 3
  local locked = paused or e >= LOCK
  local sc = 1 + 0.5 * (1 - kk)
  local lw = math.max(1, S * 0.008)
  local Rs, R1, R2 = S * 0.80 * sc, S * 0.87 * sc, S * 0.93 * sc
  local rot1, rot2 = 140 * (1 - kk), -100 * (1 - kk)
  local rc = (not paused and locked) and ALERT or ACCENT        -- lock = red, like the cross
  local snap = (not paused and e >= LOCK and e < LOCK + 0.18) and 1 or 0
  local ra = paused and 0x50 or (locked and 0x10 or 0x50)        -- hold: dim, visible
  -- soft drop shadow: ONE dark blurred underlay for brackets + cross + rings, so the scope
  -- separates from bright sky / cloud; at ~25 % ink it is invisible on dark footage
  ass:new_event()
  ass:append(string.format("{\\an7\\pos(0,%d)\\shad0\\bord%d\\blur%d\\1c&H000000&\\3c&H000000&\\1a&H%02X&\\3a&H%02X&}",
    math.max(1, math.floor(T / 2)), math.max(2, math.floor(T * 0.8)), math.max(4, math.floor(S * 0.035)), SA(0x98), SA(0x98)))
  ass:draw_start()
  geom(ass)
  if not (paused and e < BLINK and math.floor(e / BL) % 2 == 1) then cross(ass) end   -- blink-off: no cross shadow
  arc(ass, cx, cy, Rs - lw, Rs, 0, 360)
  for i = 0, 2 do arc(ass, cx, cy, R1 - lw * 1.6, R1, rot1 + i * 120 + 10, rot1 + i * 120 + 110) end
  if S >= 100 then for i = 0, 7 do arc(ass, cx, cy, R2 - lw, R2, rot2 + i * 45 + 12, rot2 + i * 45 + 33) end end
  ass:draw_stop()
  -- crosshair colour state: PAUSED = amber (2 blinks, then dims with the group); PLAY = red
  local xc, xa = ALERT, 0
  if paused then
    xc = AMBER
    if e < BLINK and math.floor(e / BL) % 2 == 1 then xa = 0xFF end           -- blink "off" phase
  end
  local gb = math.max(4, math.floor(S * 0.03))
  sh(ACCENT, A(0x70), gb, geom)                                               -- jade glow (brackets, ticks)
  sh(ACCENT, A(0x00), 0, geom)                                                -- jade core strokes
  local function XA(x) return x >= 0xFF and 0xFF or A(x) end                  -- blink off = hidden
  sh(xc, XA(xa >= 0xFF and 0xFF or 0x60 + xa / 2), gb, cross)                -- crosshair glow (off with the core)
  sh(xc, XA(xa), 0, cross)                                                    -- crosshair + dot core
  sh(ACCENT, A(paused and 0x50 or 0x60), 0, function(d) arc(d, cx, cy, Rs - lw, Rs, 0, 360) end)   -- solid ring
  sh(rc, A(ra - snap * 0x10), 0, function(d)                     -- broken ring 1: three 100 deg arcs
    for i = 0, 2 do arc(d, cx, cy, R1 - lw * (1.6 + snap), R1, rot1 + i * 120 + 10, rot1 + i * 120 + 110) end
  end)
  if S >= 100 then
    sh(rc, A(ra + 0x20), 0, function(d)                          -- broken ring 2: eight short dashes
      for i = 0, 7 do arc(d, cx, cy, R2 - lw, R2, rot2 + i * 45 + 12, rot2 + i * 45 + 33) end
    end)
  end
  local pc = paused and AMBER or rc                              -- cardinal lock pips: amber on HOLD (blink), red on lock
  local pa = paused and XA(xa + 0x10) or A(locked and 0x00 or 0x60)
  sh(pc, pa, 0, function(d)
    local pl, pw = S * 0.045, math.max(2, S * 0.022)
    for i = 0, 2 do
      local deg = i * 120 + rot1
      local ox, oy = ang(cx, cy, R1 + lw, deg); local ix, iy = ang(cx, cy, R1 - pl, deg)
      local t = math.rad(deg); local nx, ny = math.cos(t) * pw, math.sin(t) * pw
      d:move_to(ox - nx, oy - ny); d:line_to(ox + nx, oy + ny); d:line_to(ix, iy)
    end
  end)
  local big = math.floor(S * 0.17)
  local small = math.floor(S * 0.075)
  local word = paused and "HOLD" or "PLAY"
  local ly = cy + R + math.floor(S * 0.06)
  ass:new_event()
  ass:append(string.format("{\\an8\\pos(%d,%d)\\fn%s\\fs%d\\fsp%d\\bord%d\\blur%d\\shad%d\\4c&H000000&\\4a&H%02X&\\3c&H%s&\\3a&H%02X&\\1c&HFFFFFF&\\1a&H%02X&}%s",
    cx, ly, MONO, big, math.floor(big * 0.25), math.max(2, math.floor(big * 0.06)), math.max(3, math.floor(big * 0.12)),
    math.max(1, math.floor(big * 0.05)), SA(0x90), ACCENT, A(0x40), A(0x00), word))
  local rem = math.max(0, (mp.get_property_number("duration") or 0) - (remfx.cur(mp.get_property_number("time-pos")) or 0))
  local ti = math.floor(rem)
  local data = string.format("T-%02d:%02d", math.floor(ti / 60), ti % 60)
  local dy = cy - R - math.floor(S * 0.05)
  local tsh = string.format("\\bord%d\\blur%d\\3c&H000000&\\3a&H%02X&", math.max(1, math.floor(small * 0.12)), math.max(2, math.floor(small * 0.2)), SA(0x88))
  mtext(ass, cx - R, dy, small, ACCENT, A(0x00), data, 1, "\\fsp2" .. tsh)
  mtext(ass, cx + R, dy, small, ACCENT, A(0x00), (k < 1 or not locked) and "ACQ" or (paused and "LOCK · PAUSED" or "LOCK"), 3, "\\fsp3" .. tsh)
end
-- machined instrument box: dark plate, hairline + inner groove, corner brackets in col
local function ibox(ass, r, hot, col)
  shape(ass, INK, 0x40, function(d) d:rect_cw(r.x, r.y, r.x + r.w, r.y + r.h) end)
  shape(ass, "FFFFFF", hot and 0x30 or 0x70, function(d) outline(d, r.x, r.y, r.w, r.h, 1) end)
  shape(ass, "FFFFFF", 0xD8, function(d) outline(d, r.x + 3, r.y + 3, r.w - 6, r.h - 6, 1) end)
  if hot then shape(ass, ACCENT, 0xE8, function(d) d:rect_cw(r.x, r.y, r.x + r.w, r.y + r.h) end) end
  shape(ass, col, 0x00, function(d)
    local l, t = math.max(5, math.floor(r.h * 0.16)), 2
    local x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
    d:rect_cw(x0, y0, x0 + l, y0 + t); d:rect_cw(x0, y0, x0 + t, y0 + l)
    d:rect_cw(x1 - l, y0, x1, y0 + t); d:rect_cw(x1 - t, y0, x1, y0 + l)
    d:rect_cw(x0, y1 - t, x0 + l, y1); d:rect_cw(x0, y1 - l, x0 + t, y1)
    d:rect_cw(x1 - l, y1 - t, x1, y1); d:rect_cw(x1 - t, y1 - l, x1, y1)
  end)
end

-- live signal meter (the f22 MUTE softkey face): 3 rows (L peak, R peak, RMS mix), 16 square
-- cells, -40 .. 0 dBFS, top 2 cells red, falling peak-hold cell; muted = same live levels in rust + MUTED tag
local function draw_meter(ass, p, er, muted)
  local N, gp = 16, math.max(1, math.floor(er.w / 60))
  if er.big then N = math.max(16, math.min(40, math.floor(er.w / 9))); gp = math.max(2, math.floor(er.w / 140)) end
  local rg = math.max(2, math.floor(er.h * 0.12))
  local ch = math.floor((er.h - 2 * rg) / 3)
  local cw = math.floor((er.w - (N - 1) * gp) / N)
  local x0 = er.x + math.floor((er.w - (N * cw + (N - 1) * gp)) / 2)
  local function cells(db) return math.max(0, math.min(N, math.floor((db + 40) / 40 * N + 0.5))) end
  local function cx(i) return x0 + (i - 1) * (cw + gp) end
  local RED = er.big and math.max(2, math.floor(N * 0.1 + 0.5)) or 2   -- top ~4 dB red
  if er.big then
    local lf2 = math.max(8, math.floor(p.fs * 0.62))
    local nm = { "L", "R", "Σ" }
    for k = 1, 3 do
      mtext(ass, er.lx + math.floor(lf2 * 0.2), er.y + (k - 1) * (ch + rg) + ch / 2, lf2, muted and RUST or "FFFFFF",
        muted and 0x40 or 0x70, nm[k], 4)
    end
    local yb = er.y + er.h + 2                      -- dB scale notches: -40 -30 -20 -10 -6 -3 0
    local mk = {}
    for _, db in ipairs({ -40, -30, -20, -10, -6, -3, 0 }) do mk[#mk + 1] = { cx(math.max(1, cells(db))) + (db == -40 and 0 or cw), db } end
    shape(ass, "FFFFFF", 0x80, function(d) for _, m in ipairs(mk) do d:rect_cw(m[1], yb, m[1] + 1, yb + (m[2] % 10 == 0 and 4 or 2)) end end)
    local cf = math.max(7, math.floor(p.fs * 0.56))
    for _, db in ipairs({ -20, -10, 0 }) do
      local x = cx(math.max(1, cells(db))) + (db == -40 and 0 or cw)
      mtext(ass, x, yb + 4, cf, db == 0 and ALERT or "FFFFFF", db == 0 and 0x30 or 0x80, tostring(db), db == -40 and 7 or (db == 0 and 9 or 8))
    end
    mtext(ass, er.lx, er.y + er.h + er.cap, math.floor(p.fs * 0.66), muted and RUST or "FFFFFF", muted and 0x00 or 0x50,
      "MUTE", 1, "\\fsp2")
  end
  for k = 1, 3 do
    local y = er.y + (k - 1) * (ch + rg)
    local lit, pkc = cells(eq.lv[k]), cells(eq.pk[k])   -- muted: still the real signal (astats sits before mpv's mute)
    shape(ass, "FFFFFF", 0xC8, function(d)          -- unlit cells: same dim grey, so rust levels read when muted
      for i = lit + 1, N do if i ~= pkc then d:rect_cw(cx(i), y, cx(i) + cw, y + ch) end end
    end)
    if lit > 0 and muted then
      shape(ass, RUST, 0x00, function(d) for i = 1, lit do d:rect_cw(cx(i), y, cx(i) + cw, y + ch) end end)
    elseif lit > 0 then
      shape(ass, ACCENT, 0x00, function(d) for i = 1, math.min(lit, N - RED) do d:rect_cw(cx(i), y, cx(i) + cw, y + ch) end end)
      if lit > N - RED then
        shape(ass, ALERT, 0x00, function(d) for i = N - RED + 1, lit do d:rect_cw(cx(i), y, cx(i) + cw, y + ch) end end)
      end
    end
    if pkc > lit and pkc > 0 then
      shape(ass, muted and RUST or (pkc > N - RED and ALERT or ACCENT), 0x00, function(d) d:rect_cw(cx(pkc), y, cx(pkc) + cw, y + ch) end)
    end
  end
  if er.tile then                                 -- corner brackets: same machined family as the other boxes
    local r, col = er.tile, muted and RUST or ACCENT
    shape(ass, col, 0x00, function(d)
      local l, t = math.max(5, math.floor(r.h * 0.16)), 2
      local x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
      d:rect_cw(x0, y0, x0 + l, y0 + t); d:rect_cw(x0, y0, x0 + t, y0 + l)
      d:rect_cw(x1 - l, y0, x1, y0 + t); d:rect_cw(x1 - t, y0, x1, y0 + l)
      d:rect_cw(x0, y1 - t, x0 + l, y1); d:rect_cw(x0, y1 - l, x0 + t, y1)
      d:rect_cw(x1 - l, y1 - t, x1, y1); d:rect_cw(x1 - t, y1 - l, x1, y1)
    end)
  end
  if muted then                                   -- MUTED tag over the rust cells
    local tf = math.max(8, math.floor(p.fs * 0.66))
    local tw, th = math.floor(5 * tf * 0.62 + tf * 1.0), math.floor(tf * 1.3)
    local tx, ty = math.floor(er.x + er.w / 2 - tw / 2), math.floor(er.y + er.h / 2 - th / 2)
    shape(ass, INK, 0x00, function(d) d:rect_cw(tx, ty, tx + tw, ty + th) end)
    shape(ass, RUST, 0x00, function(d) outline(d, tx, ty, tw, th, 1) end)
    mtext(ass, tx + tw / 2, ty + th / 2, tf, RUST, 0x00, "MUTED", 5, "\\b1\\fsp1")
  end
end

local function draw_f22(ass, p, b, w, h, pos, dur, st)
  local fs, lf = p.fs, p.lf or math.floor(p.fs * 0.7)
  -- top HUD strip: soft dark band, hairline with brackets, title ticker, data line
  local nv = p.nav
  if nv then
    local yb = nv.dy + math.floor(fs * 0.9)
    for i = 0, 11 do
      local ya, yb2 = math.floor(yb * i / 12), math.floor(yb * (i + 1) / 12)
      shape(ass, INK, 0x28 + math.floor(0xD7 * ((i + 1) / 12) ^ 1.6), function(d) d:rect_cw(0, ya, w, yb2) end)
    end
    shape(ass, "FFFFFF", 0xC0, function(d) d:rect_cw(nv.x0, nv.y0 + nv.h, nv.x1, nv.y0 + nv.h + 1) end)
    shape(ass, ACCENT, 0x40, function(d)
      d:rect_cw(nv.x0, nv.y0 + nv.h - 5, nv.x0 + 1, nv.y0 + nv.h + 1); d:rect_cw(nv.x1 - 1, nv.y0 + nv.h - 5, nv.x1, nv.y0 + nv.h + 1)
    end)
    -- quiet info line: muted amber labels, brighter amber values, faint amber glow (same events)
    if not hud.light and boot_ok(2) then           -- LIGHT: no info line
    local function kv(k, v) return C(INFO_LBL, 0x18) .. k .. " " .. C(INFO_VAL, 0x00) .. v .. "   " end
    local vh = mp.get_property_number("video-params/h")
    local fps = mp.get_property_number("container-fps") or mp.get_property_number("estimated-vf-fps")
    local codec = (mp.get_property("video-format") or "--"):upper()
    local line = kv("CH", channel()) .. kv("RES", vh and (vh .. "P") or "--") ..
      kv("FPS", fps and string.format("%d", math.floor(fps + 0.5)) or "--") .. kv("CODEC", codec)
    mtext(ass, nv.x0, nv.dy, math.floor(fs * 0.8), INFO_VAL, 0x00, line, 4, info_glow(fs))
    mtext(ass, nv.x1, nv.dy, math.floor(fs * 0.8), INFO_VAL, 0x00, C(INFO_LBL, 0x18) .. "LCL " .. C(INFO_VAL, 0x00) .. os.date("%H:%M"), 6, info_glow(fs))
    end
  end
  if not hud.light then                            -- LIGHT: no tapes, no scope / crosshair / rings
    if p.FS and boot_ok(3) then draw_fs(ass, p, b, w, h, mp.get_property_number("time-pos"), mp.get_property_number("duration")) end
    if boot_ok(4) then draw_fpm(ass, w, h, p.u, p.FS) end
  end
  local nb, hb = b.new, b.help
  mtext(ass, nb.x + nb.w / 2, nv and nv.dy or nb.y + nb.h + fs, math.floor(lf * 0.95), INFO_LBL, 0x18, "NEW", 5, info_glow(fs, 2))
  mtext(ass, hb.x + hb.w / 2, nv and nv.dy or hb.y + hb.h + fs, math.floor(lf * 0.95), INFO_LBL, 0x18, "HELP", 5, info_glow(fs, 2))
  if not b.seek then return end
  -- readout row: ELAPSED box | status | REMAIN box (airspeed / altitude style boxes with pointers)
  local ry = p.y + math.floor(p.u * 0.32 + fs * 0.95)
  local bf = math.floor(fs * 1.12)
  local function rbox(x, an, label, val, ptr, vcol, ocol, othick, lcol, vlen)
    local tw = math.floor((vlen or #val) * bf * 0.6 + #label * lf * 0.62 + lf * 1.8)
    local bh = math.floor(bf * 1.45)
    local x0 = an == 4 and x or x - tw
    shape(ass, INK, 0x50, function(d) d:rect_cw(x0, ry - bh / 2, x0 + tw, ry + bh / 2) end)
    shape(ass, ocol or "FFFFFF", ocol and 0x00 or 0x60, function(d) outline(d, x0, math.floor(ry - bh / 2), tw, bh, othick or 1) end)
    local k = math.floor(bh * 0.22)                 -- pointer notch toward the tape centre
    shape(ass, ocol or ACCENT, 0x00, function(d)
      if ptr > 0 then tri(d, x0 + tw + 1, ry - k, x0 + tw + 1, ry + k, x0 + tw + 1 + k, ry)
      else tri(d, x0 - 1, ry - k, x0 - 1, ry + k, x0 - 1 - k, ry) end
    end)
    mtext(ass, x0 + math.floor(lf * 0.6), ry, lf, lcol or "FFFFFF", lcol and 0x20 or 0x70, label, 4, "\\fsp2")
    mtext(ass, x0 + tw - math.floor(lf * 0.6), ry, bf, vcol or "FFFFFF", 0x00, val, 6, "\\fsp1")
    return x0, tw
  end
  -- ELP: calm count-up, steady jade HH:MM:SS (whole seconds only, no motion)
  local function whole(t, pre)                          -- LIGHT: whole seconds only (no 25 Hz digits)
    local i = math.max(0, math.floor(t or 0))
    return (pre or "") .. (i >= 3600 and string.format("%d:%02d:%02d", math.floor(i / 3600), math.floor(i / 60) % 60, i % 60)
      or string.format("%02d:%02d", math.floor(i / 60), i % 60))
  end
  local et, el
  if hud.light then et = whole(pos); el = #et
  else et, el = tms(remfx.cur(pos), bf, 0x60) end        -- 07:59.482, ms smaller + dimmer
  local ebx, ebw = rbox(p.cx0, 4, "ELP", et, 1, ACCENT, nil, nil, ACCENT, el)
  if not hud.light and boot_ok(3) then  -- HDG 127° · 35 %: the run as a heading (matches the compass row on the tape) + percent
    local fr = (pos and dur and dur > 0) and math.max(0, math.min(1, pos / dur)) or 0
    local hf = math.floor(bf * 0.82)
    local hx = ebx + ebw + math.floor(lf * 1.6)
    local cw1, cw2 = lf * 0.62, hf * 0.6
    local need = 4 * cw1 + 4 * cw2 + 6 * cw1 + lf
    local stw = (#(st or "PLAYING") + 2) * fs * 0.9 * 0.62
    if hx + need < (p.cx0 + p.cx1) / 2 - stw / 2 - lf then
      mtext(ass, hx, ry, lf, "FFFFFF", 0x70, "HDG", 4, "\\fsp2")
      hx = hx + math.floor(4 * cw1 + lf * 0.3)
      mtext(ass, hx, ry, hf, ACCENT, 0x00, string.format("%03d°", math.floor(fr * 360 + 0.5)), 4, "\\fsp1")
      hx = hx + math.floor(4 * cw2 + lf * 0.8)
      mtext(ass, hx, ry, lf, "FFFFFF", 0x50, string.format("%3d%%", math.floor(fr * 100)), 4, "\\fsp1")
    end
  end
  -- REM: military countdown T-MM:SS.mmm, colour by remaining fraction, flashes red at the end
  local rem, cd = remfx.state(pos, dur)
  local LIVE = is_live()
  local x0, rw0
  if LIVE then                                             -- live stream: no countdown, no NEXT tag
    local blink = mp.get_property_bool("pause") and AMBER or ALERT
    x0, rw0 = rbox(p.cx1, 6, "SIG", "● LIVE", -1, blink, blink, 2, ACCENT, 6)
    cd.frm = nil
  else
    local rt, rl
    if hud.light then rt = whole(cd.rem, "T-"); rl = #rt
    else rt, rl = tms(cd.rem, bf, nil, "T-") end           -- ms smaller, same colour, running fast
    x0, rw0 = rbox(p.cx1, 6, cd.label, rt, -1, cd.vcol, cd.ocol, cd.othick, cd.vcol, rl)
  end
  p.remx, p.remy = x0 + rw0, ry - math.floor(bf * 1.45) / 2   -- the seek key hint sits just above it
  -- NEXT card: in the final ramp stage, and only when there really is a next item (no LOOP / END card)
  local nk = (not LIVE and dur and dur > 0 and cd.nextwin) and remfx.nexti() or nil
  if nk then
    local what, nxt = "NEXT VIDEO", nil
    do
      local k = nk
      nxt = mp.get_property("playlist/" .. k .. "/title") or mp.get_property("playlist/" .. k .. "/filename") or ""
      if not mp.get_property("playlist/" .. k .. "/title") then        -- no title yet: show the video ID
        nxt = nxt:match("[?&]v=([%w_%-]+)") or nxt:match("youtu%.be/([%w_%-]+)") or nxt:gsub("^.*/", "")
      end
      nxt = clean_title(unent(nxt)):gsub("[{}\\]", "")
    end
    local sec = math.max(0, cd.rem)
    if hud.light then                                      -- LIGHT: one tiny text line, no box
      mtext(ass, p.cx1, math.floor(ry - bf * 0.725 - math.max(4, p.u * 0.18)), math.floor(lf * 0.95), ALERT, 0x10,
        string.format("%s IN %02ds", what, math.floor(sec)), 3, "\\fsp1")
      sec = nil
    end
    if sec then
    local whole, tenth = math.floor(sec), math.floor((sec % 1) * 10)
    local tf, nf = math.floor(bf * 0.85), math.floor(lf * 1.0)
    local head = what .. " IN "
    local num = string.format("%02d", whole)
    local tail = string.format(".%ds", tenth)
    local tw = math.floor((#head + #num + #tail) * tf * 0.62 + tf * 1.6)
    if nxt and nxt ~= "" then
      local maxc = math.floor(math.max(tw * 1.6, (rw0 or tw) * 1.4) / (nf * 0.62))
      if #nxt > maxc then nxt = nxt:sub(1, maxc - 1) .. "…" end
      tw = math.max(tw, math.floor(#nxt * nf * 0.62 + nf * 1.6))
    end
    local th3 = math.floor(tf * 1.6) + ((nxt and nxt ~= "") and math.floor(nf * 1.35) or 0)
    local bh0 = math.floor(bf * 1.45)
    local bx, by = math.floor(p.cx1 - tw), math.floor(ry - bh0 / 2 - th3 - math.max(4, p.u * 0.18))
    local br = { x = bx, y = by, w = tw, h = th3 }
    ibox(ass, br, false, ALERT)
    shape(ass, cd.ocol or ALERT, 0x00, function(d) outline(d, bx, by, tw, th3, 1) end)   -- frame breathes with REM
    local ly0 = by + math.floor(tf * 0.85)
    mtext(ass, bx + math.floor(tf * 0.7), ly0, tf, "FFFFFF", 0x30, head ..
      "{\\b1}" .. C(ALERT, 0x00) .. num .. "{\\b0}" .. C(ALERT, 0x50) .. tail, 4, "\\fsp1")
    if nxt and nxt ~= "" then
      mtext(ass, bx + math.floor(tf * 0.7), by + th3 - math.floor(nf * 0.95), nf, "FFFFFF", 0x60, nxt, 4)
    end
    end
  end
  if cd.frm and not hud.light then   -- secondary fast row: frame counter (estimated-frame-number / -count)
    mtext(ass, x0 - math.floor(lf * 0.9), ry, math.floor(lf * 0.92), cd.ocol or "FFFFFF", cd.ocol and 0x30 or 0x60, cd.frm, 6, "\\fsp1")
  end
  mtext(ass, math.floor((p.cx0 + p.cx1) / 2), ry, math.floor(fs * 0.9), st == "PAUSED" and AMBER or ACCENT, 0x00,
    st_icon(math.floor(fs * 0.9), st == "PAUSED") .. (st or "PLAYING"), 5, "\\fsp3")
  -- labels under the side softkeys
  local function lab(x, txt) mtext(ass, x, p.laby, math.floor(fs * 0.68), "FFFFFF", 0x58, txt, 8, "\\fsp2") end
  local vol, muted = mp.get_property_number("volume") or 0, mp.get_property_bool("mute")
  if b.vol and not p.hero then
    if muted then mtext(ass, b.vol.x + b.vol.w / 2, p.laby, math.floor(fs * 0.68), RUST, 0x00, "MUTE", 8, "\\fsp2")
    else lab(b.vol.x + b.vol.w / 2, "MUTE") end
  end
  if p.rgrp then                                 -- SIZE / FS group plate (keys drawn on top later)
    local gr = p.rgrp
    ibox(ass, gr, false, ACCENT)
    local cy2 = gr.y + gr.h - gr.ip - math.floor(gr.cap * 0.45)
    mtext(ass, b.smaller.x + b.smaller.w + math.floor((b.larger.x - b.smaller.x - b.smaller.w) / 2), cy2,
      math.floor(fs * 0.62), "FFFFFF", 0x58, "SIZE", 5, "\\fsp2")
    mtext(ass, b.fs.x + b.fs.w / 2, cy2, math.floor(fs * 0.62), "FFFFFF", 0x58, "FS", 5, "\\fsp2")
    if b.hud then mtext(ass, b.hud.x + b.hud.w / 2, cy2, math.floor(fs * 0.62), "FFFFFF", 0x58, "HUD", 5, "\\fsp2") end
    if b.pin then mtext(ass, b.pin.x + b.pin.w / 2, cy2, math.floor(fs * 0.62), "FFFFFF", 0x58, "PIN", 5, "\\fsp2") end
  else
    if b.hud then lab(b.hud.x + b.hud.w / 2, "HUD") end
    if b.pin then lab(b.pin.x + b.pin.w / 2, "PIN") end
    if b.smaller then lab(b.smaller.x + b.smaller.w, "SIZE") end
    if b.fs then lab(b.fs.x + b.fs.w / 2, "FS") end
  end
  -- VOL gauge: 10 square segments, lit to the level; click / drag to set
  local r = b.vgauge
  if r and p.hero then
    local hb = p.hero
    local hot = state.hot == "vgauge" or state.vdrag == "vgauge"
    local fc = muted and RUST or ACCENT
    shape(ass, INK, 0x40, function(d) d:rect_cw(hb.x, hb.y, hb.x + hb.w, hb.y + hb.h) end)       -- machined frame
    shape(ass, "FFFFFF", hot and 0x30 or 0x70, function(d) outline(d, hb.x, hb.y, hb.w, hb.h, 1) end)
    shape(ass, "FFFFFF", 0xD8, function(d) outline(d, hb.x + 3, hb.y + 3, hb.w - 6, hb.h - 6, 1) end)
    shape(ass, fc, 0x00, function(d)                                                             -- corner brackets
      local l, t = math.max(5, math.floor(hb.h * 0.16)), 2
      d:rect_cw(hb.x, hb.y, hb.x + l, hb.y + t); d:rect_cw(hb.x, hb.y, hb.x + t, hb.y + l)
      d:rect_cw(hb.x + hb.w - l, hb.y, hb.x + hb.w, hb.y + t); d:rect_cw(hb.x + hb.w - t, hb.y, hb.x + hb.w, hb.y + l)
      d:rect_cw(hb.x, hb.y + hb.h - t, hb.x + l, hb.y + hb.h); d:rect_cw(hb.x, hb.y + hb.h - l, hb.x + t, hb.y + hb.h)
      d:rect_cw(hb.x + hb.w - l, hb.y + hb.h - t, hb.x + hb.w, hb.y + hb.h); d:rect_cw(hb.x + hb.w - t, hb.y + hb.h - l, hb.x + hb.w, hb.y + hb.h)
    end)
    local hy = hb.y + hb.ip + math.floor(hb.hh * 0.45)                                          -- header: VOL ...... 080
    mtext(ass, hb.x + hb.ip + 2, hy, math.floor(fs * 0.68), "FFFFFF", 0x58, "VOL", 4, "\\fsp2")
    mtext(ass, hb.x + hb.w - hb.ip - 2, hy, math.floor(fs * 0.95), fc, 0x00, string.format("%03d", math.floor(vol + 0.5)), 6, "\\b1\\fsp1")
    -- notched scale + track + square thumb
    local th = math.max(3, math.floor(r.h * 0.16))
    local ty = math.floor(r.y + r.h * 0.38 - th / 2)
    local fx = math.floor(r.x + r.w * math.min(1, vol / 100) + 0.5)
    shape(ass, "FFFFFF", 0xC0, function(d) d:rect_cw(r.x, ty, r.x + r.w, ty + th) end)
    if fx > r.x then shape(ass, fc, muted and 0x40 or 0x00, function(d) d:rect_cw(r.x, ty, fx, ty + th) end) end
    local nb = ty + th + 3
    local on, off = {}, {}
    for i = 0, 20 do
      local x = math.min(r.x + r.w - 1, math.floor(r.x + r.w * i / 20))
      local l = (i % 10 == 0) and math.floor(r.h * 0.34) or ((i % 2 == 0) and math.floor(r.h * 0.2) or math.floor(r.h * 0.1))
      local list = x <= fx and on or off
      list[#list + 1] = { x, math.max(2, l) }
    end
    shape(ass, "FFFFFF", 0x80, function(d) for _, k in ipairs(off) do d:rect_cw(k[1], nb, k[1] + 1, nb + k[2]) end end)
    if #on > 0 then shape(ass, fc, 0x10, function(d) for _, k in ipairs(on) do d:rect_cw(k[1], nb, k[1] + 1, nb + k[2]) end end) end
    local q = math.max(10, math.floor(r.h * 0.78 / 2) * 2)
    local qy = math.floor(ty + th / 2 - q / 2)
    shape(ass, fc, 0x00, function(d) d:rect_cw(fx - q / 2, qy, fx + q / 2, qy + q) end, 1, INK, 0x00)
    shape(ass, INK, 0x20, function(d) d:rect_cw(fx, qy + 2, fx + 1, qy + q - 2) end)              -- grip line
  elseif r then
    -- slim notched scale: dim track, jade fill to the level, notches every 10 % (50 % / 100 % long),
    -- square needle at the level; deliberately unlike the cell meter on the MUTE key
    local th = math.max(3, math.floor(r.h * 0.22))
    local ty = math.floor(r.y + r.h * 0.42 - th / 2)
    local fx = math.floor(r.x + r.w * math.min(1, vol / 100) + 0.5)
    local fc = muted and RUST or ACCENT
    shape(ass, "FFFFFF", 0xC0, function(d) d:rect_cw(r.x, ty, r.x + r.w, ty + th) end)
    if fx > r.x then shape(ass, fc, muted and 0x40 or 0x00, function(d) d:rect_cw(r.x, ty, fx, ty + th) end) end
    local nb = ty + th + 2
    local on, off = {}, {}
    for i = 0, 10 do
      local x = math.min(r.x + r.w - 1, math.floor(r.x + r.w * i / 10))
      local l = (i % 5 == 0) and math.floor(r.h * 0.32) or math.floor(r.h * 0.16)
      local list = x <= fx and on or off
      list[#list + 1] = { x, l }
    end
    shape(ass, "FFFFFF", 0x80, function(d) for _, k in ipairs(off) do d:rect_cw(k[1], nb, k[1] + 1, nb + k[2]) end end)
    if #on > 0 then shape(ass, fc, 0x10, function(d) for _, k in ipairs(on) do d:rect_cw(k[1], nb, k[1] + 1, nb + k[2]) end end) end
    local nw = math.max(3, math.floor(th * 0.9))
    shape(ass, fc, 0x00, function(d) d:rect_cw(fx - math.floor(nw / 2), r.y, fx - math.floor(nw / 2) + nw, ty + th + 1) end, 1, INK, 0x20)
    if hot then shape(ass, ACCENT, 0x00, function(d) outline(d, r.x - 3, r.y - 3, r.w + 6, r.h + 6, 1) end) end
    -- label: dim "VOL" tag + the number bright and a touch larger (jade like ELP / REM; rust when muted)
    local cxv, nf = math.floor(r.x + r.w / 2), math.floor(fs * 0.86)
    local tf = math.floor(fs * 0.68)
    mtext(ass, cxv - math.floor(fs * 0.25), p.laby + (nf - tf), tf, muted and RUST or "FFFFFF", muted and 0x30 or 0x58,
      "VOL", 9, "\\fsp2")
    mtext(ass, cxv + math.floor(fs * 0.05), p.laby, nf, muted and RUST or ACCENT, 0x00,
      string.format("%03d", math.floor(vol + 0.5)), 7, "\\b1\\fsp1")
  end
  -- softkeys / lamps
  local spd = mp.get_property_number("speed") or 1
  local loop = (mp.get_property("loop-file") or "no") ~= "no"
  local function lamp(name, on, txt)
    local rr = b[name]; if not rr then return end
    local col, al = chrome(ass, p, name, rr, on)
    mtext(ass, rr.x + rr.w / 2, rr.y + rr.h / 2, lf, col, al, txt, 5, "\\fsp1")
  end
  if p.rhero then if boot_ok(2) then
    local ip = p.rhero.ip
    local hf, vf = math.floor(fs * 0.68), math.floor(fs * 0.95)
    local function head(r, label, val, vcol, valpha)       -- valpha: ghosted value (hover preview)
      local hy = r.y + ip + math.floor(fs * 0.45)
      mtext(ass, r.x + ip + 2, hy, hf, "FFFFFF", 0x58, label, 4, "\\fsp2")
      if val then mtext(ass, r.x + r.w - ip - 2, hy, vf, vcol, valpha or 0x00, val, 6, "\\b1\\fsp1") end
      return r.y + ip + math.floor(fs * 1.05)                -- top of the instrument area
    end
    -- SPEED: stepped selector 0.50 .. 2.00x in 0.25 steps; lit up to the rate, the rate cell framed
    do
      local r = b.spd
      local off = math.abs(spd - 1) > 0.001
      local vc = off and AMBER or ACCENT
      ibox(ass, r, state.hot == "spd", off and AMBER or ACCENT)
      local n, gp = 7, math.max(2, math.floor(r.w / 60))
      local x0, x1 = r.x + ip + 3, r.x + r.w - ip - 3
      local cw = math.floor((x1 - x0 - (n - 1) * gp) / n)
      local hy0 = r.y + ip + math.floor(fs * 1.05)
      r.cells = { x0 = x0, cw = cw, gp = gp, n = n, y0 = hy0 - 2 }     -- click / hover targets (one per cell)
      local hv = state.hot == "spd" and spd_cell_at(r, state.mx, state.my)
      local ty = head(r, "SPEED", string.format("%.2fx", hv and SPD_STEPS[hv] or spd), hv and "FFFFFF" or vc, hv and 0x70)
      local ch = math.max(4, math.floor((r.y + r.h - ip - ty) * 0.42))
      local cur = math.floor((math.max(0.5, math.min(2, spd)) - 0.5) / 0.25 + 0.5) + 1
      for i = 1, n do
        local x = x0 + (i - 1) * (cw + gp)
        local lit = i <= cur
        local one = i == 3                                  -- 1.00x reference step
        shape(ass, lit and vc or "FFFFFF", lit and (i == cur and 0x00 or 0x50) or (one and 0x90 or 0xC0),
          function(d) d:rect_cw(x, ty + 1, x + cw, ty + 1 + ch) end)
        if i == cur then shape(ass, "FFFFFF", 0x00, function(d) outline(d, x - 2, ty - 1, cw + 4, ch + 4, 1) end)
        elseif i == hv then shape(ass, AMBER, 0x30, function(d) outline(d, x - 2, ty - 1, cw + 4, ch + 4, 1) end) end
      end
      local lf3 = math.max(7, math.floor(fs * 0.56))
      local ly3 = ty + ch + 4
      mtext(ass, x0, ly3, lf3, "FFFFFF", 0x80, "0.5", 7)
      mtext(ass, x0 + 2 * (cw + gp) + cw / 2, ly3, lf3, "FFFFFF", 0x60, "1.0", 8)
      mtext(ass, x0 + 6 * (cw + gp) + cw, ly3, lf3, "FFFFFF", 0x80, "2.0", 9)
    end
    -- REPEAT: OFF | ON switch with a lamp
    do
      local r = b.loop
      ibox(ass, r, state.hot == "loop", loop and AMBER or ACCENT)
      local ty = head(r, "REPEAT", nil)
      local q = math.max(5, math.floor(fs * 0.5))           -- status lamp, top right
      shape(ass, loop and AMBER or "FFFFFF", loop and 0x00 or 0xA0, function(d)
        d:rect_cw(r.x + r.w - ip - 2 - q, r.y + ip + math.floor(fs * 0.45) - q / 2, r.x + r.w - ip - 2, r.y + ip + math.floor(fs * 0.45) + q / 2)
      end)
      local x0, x1 = r.x + ip + 3, r.x + r.w - ip - 3
      local hw = math.floor((x1 - x0 - 3) / 2)
      local sh = math.max(8, r.y + r.h - ip - 2 - ty)
      r.halves = { x0 = x0, hw = hw, y0 = ty - 2 }           -- OFF | ON are direct click targets
      local hv = state.hot == "loop" and state.my and state.my >= ty - 2 and
        (state.mx < x0 + hw + 2 and 1 or 2)
      local function half(x, on, txt, col)
        local h = not on and hv == (x == x0 and 1 or 2)
        shape(ass, on and col or "FFFFFF", on and 0x00 or (h and 0x98 or 0xC8), function(d) d:rect_cw(x, ty, x + hw, ty + sh) end)
        mtext(ass, x + hw / 2, ty + sh / 2, math.floor(fs * 0.62), on and INK or "FFFFFF", on and 0x00 or 0x70, txt, 5, "\\b1\\fsp1")
      end
      half(x0, not loop, "OFF", ACCENT)
      half(x0 + hw + 3, loop, "ON", AMBER)
    end
    -- BUFFER: live bar graph of cache seconds (last ~10 s at 4 Hz), 0 .. 60 s scale
    do
      local r = b.link
      local txt, col = link_state()
      local secs = txt:match("(%d+)s")
      ibox(ass, r, state.hot == "link", col == AMBER and AMBER or ACCENT)
      local ty = head(r, "LINK", secs and (secs .. "s") or "LOCAL", col == "FFFFFF" and "FFFFFF" or col)
      local x0, x1 = r.x + ip + 3, r.x + r.w - ip - 3
      local yb = r.y + r.h - ip - 2
      local hh = math.max(6, yb - ty)
      local n = math.max(8, math.floor((x1 - x0) / 5))
      local bw = math.max(2, math.floor((x1 - x0) / n) - 1)
      shape(ass, "FFFFFF", 0xD8, function(d) d:rect_cw(x0, ty, x1, yb) end)
      shape(ass, "FFFFFF", 0x90, function(d)                -- 10 / 30 s grid lines
        for _, v in ipairs({ 10, 30 }) do local y = math.floor(yb - hh * v / 60); d:rect_cw(x0, y, x1, y + 1) end
      end)
      local hist = linkh
      local lo, hi = {}, {}
      for i = 1, n do
        local v = hist[#hist - n + i]
        if v then
          local x = x0 + (i - 1) * (bw + 1)
          local bh = math.max(1, math.floor(math.min(60, v) / 60 * hh))
          local list = v < 5 and lo or hi
          list[#list + 1] = { x, yb - bh }
        end
      end
      shape(ass, ACCENT, 0x00, function(d) for _, k in ipairs(hi) do d:rect_cw(k[1], k[2], k[1] + bw, yb) end end)
      if #lo > 0 then shape(ass, AMBER, 0x00, function(d) for _, k in ipairs(lo) do d:rect_cw(k[1], k[2], k[1] + bw, yb) end end) end
    end
  end else
  lamp("spd", math.abs(spd - 1) > 0.001, string.format("SPD %.2fx", spd))
  lamp("loop", loop, "LOOP")
  if b.spd then lab(b.spd.x + b.spd.w / 2, "SPEED") end
  if b.loop then lab(b.loop.x + b.loop.w / 2, "REPEAT") end
  local lk = p.link
  if lk then
    local txt, col, al = link_state()
    shape(ass, "FFFFFF", 0xB0, function(d) outline(d, lk.x, lk.y, lk.w, lk.h, 1) end)
    local q = math.floor(lk.h * 0.28)
    shape(ass, col, al, function(d) d:rect_cw(lk.x + q, lk.y + lk.h / 2 - q / 2, lk.x + 2 * q, lk.y + lk.h / 2 + q / 2) end)
    mtext(ass, lk.x + lk.w - math.floor(lf * 0.5), lk.y + lk.h / 2, lf, col, al == 0x80 and 0x60 or 0x00, txt, 6, "\\fsp1")
    lab(lk.x + lk.w / 2, "BUFFER")
  end
  end
end

-- hover key hints: while the pointer rests on the bar every tile shows its key (no timer: drawn
-- by the normal render pass, gone on the next one once the pointer leaves)
local inside                           -- (set below, with hit())
local KEYCAP = { back = "J", play = "K", fwd = "L", vol = "M", vgauge = "↑↓", spd = "< >", loop = "R",
  link = "I", hud = "H", pin = "P", smaller = "-", larger = "=", fs = "F", new = "O", help = "?", seek = "0-9 ← →" }
local KEYCAP_ABOVE = { hud = true, pin = true, smaller = true, larger = true, fs = true }
local function keycaps(ass, p, b)
  local f = math.max(8, math.floor(p.fs * 0.9))
  local ch, t = math.floor(f * 1.45), math.max(1, p.t or 1)
  local caps = {}
  for name, s in pairs(KEYCAP) do
    local r = b[name]
    if r then
      local cw = math.floor(select(2, s:gsub("[^\128-\191]", "")) * f * 0.62 + f * 0.75)
      local x, y
      if name == "new" then x, y = r.x + r.w + 3, r.y + (r.h - ch) / 2
      elseif name == "help" then x, y = r.x - 3 - cw, r.y + (r.h - ch) / 2
      elseif name == "play" then x, y = r.x + (r.w - cw) / 2, r.y - ch * 0.6
      elseif KEYCAP_ABOVE[name] then x, y = r.x + (r.w - cw) / 2, r.y - ch - 2
      elseif name == "seek" and p.remx then x, y = p.remx - cw, p.remy - ch - 3
      elseif name == "seek" then x, y = r.x + r.w - cw, r.y - ch - 2
      else x, y = r.x + r.w - cw, r.y - ch * 0.6 end
      caps[#caps + 1] = { x = math.floor(x), y = math.floor(y), w = cw, s = s }
    end
  end
  shape(ass, INK, 0x73, function(d) for _, c in ipairs(caps) do d:rect_cw(c.x, c.y, c.x + c.w, c.y + ch) end end)
  shape(ass, ACCENT, 0x10, function(d) for _, c in ipairs(caps) do outline(d, c.x, c.y, c.w, ch, t) end end)
  for _, c in ipairs(caps) do mtext(ass, c.x + c.w / 2, c.y + ch / 2, f, ACCENT, 0x00, c.s, 5, "\\b1") end
end
render = function()
  frame.t = mp.get_time()
  local w, h = mp.get_osd_size()
  if not w or w <= 0 or h <= 0 then ov:remove(); return end
  local p, b = layout(w, h)
  state.panel, state.buttons = p, b
  if state.fade <= 0 then ov:remove(); return end
  local ass = assdraw.ass_new()
  local paused, muted = mp.get_property_bool("pause"), mp.get_property_bool("mute")
  local full = mp.get_property_bool("fullscreen")
  local k = stroke(p)
  if b.seek then
    if HUD() then            -- instrument module: dark glass, 1px frame, brackets, scanlines
      shape(ass, INK, 0x40, function(d) d:rect_cw(p.x, p.y, p.x + p.w, p.y + p.h) end)
      shape(ass, "FFFFFF", 0xF6, function(d)
        for y = p.y + 2, p.y + p.h - 2, 3 do d:rect_cw(p.x + 1, y, p.x + p.w - 1, y + 1) end
      end)
      shape(ass, "FFFFFF", 0xB8, function(d) outline(d, p.x, p.y, p.w, p.h, 1) end)
      shape(ass, ACCENT, 0x00, function(d) ticks(d, p.x, p.y, p.w, p.h, 2, math.floor(p.u * 0.5)) end)
      local nb, hb = b.new, b.help           -- rails tying the corner buttons to the module
      shape(ass, ACCENT, 0x98, function(d)
        local y0 = nb.y + nb.h + (style == "f22" and math.floor(p.fs * 1.5) or 4)
        d:rect_cw(nb.x, y0, nb.x + 1, p.y - 4)
        d:rect_cw(hb.x + hb.w - 1, y0, hb.x + hb.w, p.y - 4)
      end)
    elseif style == "frame" then          -- one hairline panel with jade corner ticks
      shape(ass, INK, 0x48, function(d) d:rect_cw(p.x, p.y, p.x + p.w, p.y + p.h) end)
      shape(ass, ACCENT, 0x90, function(d) outline(d, p.x, p.y, p.w, p.h, p.t) end)
      shape(ass, ACCENT, 0x00, function(d) ticks(d, p.x, p.y, p.w, p.h, p.t + 1, math.floor(p.u * 0.45)) end)
    else                              -- no container: a soft dark scrim rising from the edge
      local y0, N = p.y - p.u, 32
      local deep = style == "edge" and 0x30 or 0x60
      for i = 0, N - 1 do
        local ya, yb = math.floor(y0 + (h - y0) * i / N), math.floor(y0 + (h - y0) * (i + 1) / N)
        local al = 255 - math.floor((255 - deep) * ((i + 1) / N) ^ 1.6)
        shape(ass, INK, al, function(d) d:rect_cw(0, ya, w, yb) end)
      end
    end
    draw_seek(ass, p, b.seek)
    local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
    local s = status_text()
    local fs = p.fs
    local mx, my = p.mid.x, p.mid.cy
    local room = math.floor(p.mid.w / (fs * 0.62))
    if HUD() then
      if style == "f22" then draw_f22(ass, p, b, w, h, pos, dur, s); if boot_ok(2) then draw_title(ass, p, w, h) end else
      -- digital readout row above the scale: STATUS left, elapsed / total right
      local ry = p.y + (p.tth or 0) + math.floor(p.u * 0.3 + fs * 0.6)
      mtext(ass, p.cx1, ry, fs, "FFFFFF", 0x00,
        dtime(pos) .. C("FFFFFF", 0x90) .. " / " .. dtime(dur), 6, "\\fsp1")
      mtext(ass, p.cx0, ry, math.floor(fs * 0.92), ACCENT, 0x00,
        st_icon(math.floor(fs * 0.92), s == "PAUSED") .. (s or "PLAYING"), 4, "\\fsp3")
      draw_title(ass, p, w, h)
      local function lab(x, txt) mtext(ass, x, p.laby, math.floor(fs * 0.72), "FFFFFF", 0x58, txt, 8, "\\fsp2") end
      if b.vol then lab(b.vol.x + b.vol.w / 2, "VOL") end
      if b.smaller then lab(b.smaller.x + b.smaller.w, "SIZE") end
      if b.fs then lab(b.fs.x + b.fs.w / 2, "FS") end
      end
    elseif style == "edge" then
      mtext(ass, p.tl.x, p.tl.y, fs, "FFFFFF", 0x00, fmt_time(pos), 4)
      mtext(ass, p.tr.x, p.tr.y, fs, "FFFFFF", 0x60, fmt_time(dur), 6)
      if s and #s <= room then mtext(ass, mx, my, math.floor(fs * 0.95), ACCENT, 0x00, s, 4, "\\fsp3") end
    else
      local tm = fmt_time(pos) .. " / " .. fmt_time(dur)
      local body = C("FFFFFF", 0x00) .. fmt_time(pos) .. C("FFFFFF", 0x70) .. " / " .. fmt_time(dur)
      local sl = s and (style == "segment" and "[" .. s .. "]" or s)
      if sl and #sl + 2 + #tm <= room then
        body = C(ACCENT, 0x00) .. (style == "frame" and "{\\fsp2}" or "") .. sl .. "{\\fsp0}" .. C("FFFFFF", 0x80) .. "  " .. body
      elseif sl and #sl <= room then body = C(ACCENT, 0x00) .. sl
      elseif #tm > room then body = C("FFFFFF", 0x00) .. fmt_time(pos) end
      if room >= 4 then mtext(ass, mx, my, fs, "FFFFFF", 0x00, body, 4) end
    end
    local function btn(name, on, glyph)
      local r = b[name]; if not r then return end
      local col, al = chrome(ass, p, name, r, on)
      glyph(r, col, al)
    end
    btn("back", false, function(r, c, al) mtext(ass, r.x + r.w / 2, r.y + r.h / 2, math.floor(r.h * 0.38), c, al, "-10", 5) end)
    if style == "f22" and b.play and not hud.light and boot_ok(1) then draw_dial(ass, p, b.play, paused, muted) else
    btn("play", style == "f22" or not paused, function(r, c, al)   -- f22: jade while playing, amber while paused
      g_play(ass, r, c, al, paused)
      if paused and style == "f22" and r.h >= 30 then
        mtext(ass, r.x + r.w / 2, r.y + r.h - math.floor(r.h * 0.07), math.max(7, math.floor(r.h * 0.13)), c, al, "HOLD", 2, "\\fsp2")
      end
    end)
    end
    btn("fwd", false, function(r, c, al) mtext(ass, r.x + r.w / 2, r.y + r.h / 2, math.floor(r.h * 0.38), c, al, "+10", 5) end)
    btn("vol", muted, function(r, c, al)
      if style == "f22" and p.eq and eq.have and boot_ok(4) then draw_meter(ass, p, p.eq, muted)
      else g_vol(ass, p, r, c, al, muted, mp.get_property_number("volume")) end
    end)
    btn("smaller", false, function(r, c, al) g_line(ass, r, c, al, false, k) end)
    btn("larger", false, function(r, c, al) g_line(ass, r, c, al, true, k) end)
    btn("fs", full, function(r, c, al) g_fs(ass, r, c, al, full, k) end)
    btn("hud", false, function(r, c, al)            -- CRUISE: small neon green dot on (a nudge to engage); COMBAT: tile muted gray, dot off
      local q = math.max(4, math.floor(r.h * 0.2))
      local lx, ly = r.x + r.w - q - math.max(2, math.floor(r.h * 0.12)), r.y + math.max(2, math.floor(r.h * 0.12))
      local cx, cy, rr = lx + q / 2, ly + q / 2, q / 2
      local function dot(d, rad)                    -- 16-gon (shape() records polygons only)
        d:move_to(cx + rad, cy)
        for i = 1, 15 do local t = i * math.pi / 8; d:line_to(cx + rad * math.cos(t), cy + rad * math.sin(t)) end
      end
      local lc, la = c, al
      if hud.light then                              -- static draw only, no timers: dot + one tight halo
        shape(ass, TILE_GREEN, 0xB8, function(d) dot(d, rr + 2) end)
        shape(ass, TILE_GREEN, 0x00, function(d) dot(d, rr) end)
        if q >= 8 then shape(ass, TILE_CORE, 0x30, function(d) dot(d, rr * 0.45) end) end
      else
        shape(ass, TILE_GRAY, 0xA0, function(d) dot(d, rr) end)   -- dot off
        if state.hot ~= "hud" then lc, la = TILE_GRAY, 0x30 end
      end
      mtext(ass, r.x + r.w / 2, r.y + math.floor(r.h * 0.6), math.max(7, math.floor(r.h * 0.3)), lc, la, "HUD", 5, "\\fsp1")
    end)
    btn("pin", false, function(r, c, al)           -- PIN: green lamp dot on while pinned (HUD-tile family), gray off
      local q = math.max(4, math.floor(r.h * 0.2))
      local lx, ly = r.x + r.w - q - math.max(2, math.floor(r.h * 0.12)), r.y + math.max(2, math.floor(r.h * 0.12))
      local cx, cy, rr = lx + q / 2, ly + q / 2, q / 2
      local function dot(d, rad)
        d:move_to(cx + rad, cy)
        for i = 1, 15 do local t = i * math.pi / 8; d:line_to(cx + rad * math.cos(t), cy + rad * math.sin(t)) end
      end
      local lc, la = c, al
      if hud.pin then
        shape(ass, TILE_GREEN, 0xB8, function(d) dot(d, rr + 2) end)
        shape(ass, TILE_GREEN, 0x00, function(d) dot(d, rr) end)
        if q >= 8 then shape(ass, TILE_CORE, 0x30, function(d) dot(d, rr * 0.45) end) end
      else
        shape(ass, TILE_GRAY, 0xA0, function(d) dot(d, rr) end)
        if state.hot ~= "pin" then lc, la = TILE_GRAY, 0x30 end
      end
      mtext(ass, r.x + r.w / 2, r.y + math.floor(r.h * 0.6), math.max(7, math.floor(r.h * 0.3)), lc, la, "PIN", 5, "\\fsp1")
    end)
  end
  if style == "f22" and not b.seek then draw_f22(ass, p, b, w, h) end
  for _, name in ipairs({ "new", "help" }) do   -- top corners: small hairline squares
    local r = b[name]
    shape(ass, INK, 0xA8, function(d) d:rect_cw(r.x, r.y, r.x + r.w, r.y + r.h) end)
    local col, al = chrome(ass, p, name, r, false)
    if name == "new" then g_line(ass, r, col, al, true, k)
    else mtext(ass, r.x + r.w / 2, r.y + r.h / 2, math.floor(p.fs * 1.3), col, al, "?", 5) end
  end
  if hud.keyhints and not state.dragging and not state.vdrag then keycaps(ass, p, b) end   -- KEY HINTS (? panel, T): on every control, no hover; off by default
  local ht = state.htag                          -- hover seek tag: top z, mm:ss.mmm, clamped to the bar
  if ht and HUD() then
    local t = math.max(0, ht.t)
    local hh, mm, ss = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    local s = hh > 0 and string.format("%d:%02d:%06.3f", hh, mm, ss) or string.format("%02d:%06.3f", mm, ss)
    local r = ht.r
    local fw = math.floor(p.fs * 1.2)
    local tw, th2 = math.floor(#s * fw * 0.62 + fw * 1.2), math.floor(fw * 1.75)
    local k = math.max(4, math.floor(fw * 0.35))                 -- notch down to the pointer
    local L, R = (p.x or 0) + 4, (p.x or 0) + (p.w or w) - 4
    local tx = math.floor(math.max(L, math.min(R - tw, ht.mx - tw / 2)))
    local ty = math.floor(r.y - th2 - k - 2)
    local nx = math.max(tx + k + 2, math.min(tx + tw - k - 2, ht.mx))
    shape(ass, INK, 0x00, function(d) d:rect_cw(tx, ty, tx + tw, ty + th2) end)
    shape(ass, ACCENT, 0x00, function(d)
      outline(d, tx, ty, tw, th2, math.max(1, p.t))
      tri(d, nx - k, ty + th2, nx + k, ty + th2, nx, ty + th2 + k)
      d:rect_cw(ht.mx, ty + th2 + k, ht.mx + 1, r.y + math.floor(r.h / 2))
    end)
    mtext(ass, tx + tw / 2, ty + th2 / 2, fw, "FFFFFF", 0x00, s, 5, "\\b1\\fsp1")
  end
  state.htag = nil
  ov.res_x, ov.res_y, ov.data = w, h, ass.text
  ov:update()
end

-- input section: only the bar captures clicks ----------------------------------------------
local function publish()  -- user-data/omaraptor-hud: handy for IPC checks
  mp.set_property_native("user-data/omaraptor-hud", { visible = state.visible, position = "bottom",
    panel = state.panel, pinned = hud.pin })
end

local tips_open = false
local function set_section(on)
  if on and state.panel then
    local p, hb = state.panel, state.buttons.help
    mp.set_mouse_area(p.x, p.y, p.x + p.w, p.y + p.h, SECTION)
    if hb then mp.set_mouse_area(hb.x, hb.y, hb.x + hb.w, hb.y + hb.h, HELP_SECTION) end
    local nb = state.buttons.new
    if nb then mp.set_mouse_area(nb.x, nb.y, nb.x + nb.w, nb.y + nb.h, NEW_SECTION) end
    for k, sec in pairs(TAPES) do
      local r = state.buttons[k]; r = r and (r.grab or r)
      if r then mp.set_mouse_area(r.x, r.y, r.x + r.w, r.y + r.h, sec) else mp.set_mouse_area(0, 0, 0, 0, sec) end
    end
    if not state.section_on then
      -- no "allow-vo-dragging": a press on the bar must not start a window drag
      mp.input_enable_section(SECTION, "allow-hide-cursor")
      mp.input_enable_section(HELP_SECTION, "allow-hide-cursor")
      mp.input_enable_section(NEW_SECTION, "allow-hide-cursor")
      for _, sec in pairs(TAPES) do mp.input_enable_section(sec, "allow-hide-cursor") end
      state.section_on = true
      if tips_open then   -- keep the open panel's section on top of the bar
        mp.input_disable_section(TIPS_SECTION); mp.input_enable_section(TIPS_SECTION)
      end
      if hud.card_raise then hud.card_raise() end
    end
  elseif not on and state.section_on then
    mp.input_disable_section(SECTION)
    mp.input_disable_section(HELP_SECTION)
    mp.input_disable_section(NEW_SECTION)
    for _, sec in pairs(TAPES) do mp.input_disable_section(sec) end
    state.section_on = false
  end
  publish()
end

inside = function(r, x, y)
  return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local function hit(x, y)
  for name, r in pairs(state.buttons) do
    if name ~= "time" and inside(r.grab or r, x, y) then return name end
  end
end

-- show / hide --------------------------------------------------------------------------------
local function stop_fade() if fade_timer then fade_timer:kill(); fade_timer = nil end end

local function fade_to(target, done)
  stop_fade()
  local step = (target - state.fade) / FADE_STEPS
  if step == 0 then if done then done() end; return end
  fade_timer = mp.add_periodic_timer(FADE_TIME / FADE_STEPS, function()
    state.fade = state.fade + step
    if (step > 0 and state.fade >= target) or (step < 0 and state.fade <= target) then
      state.fade = target
      stop_fade()
      if done then done() end
    end
    render()
  end)
end

local function hide(now)
  hide_timer:kill()
  state.hot = nil
  state.visible = false
  state.dragging = false
  set_section(false)
  tick_timer:kill()
  marquee_run(false)
  remfx.sync()
  if now then stop_fade(); state.fade = 0; ov:remove(); if eq.rate then eq.rate(false) end; return end
  fade_to(0, function() ov:remove(); if eq.rate then eq.rate(false) end end)
end

local function arm_hide(secs)
  hide_timer:kill()
  hide_timer.timeout = secs or opts.timeout
  hide_timer:resume()
end

local function show(secs)
  if state.boot then return end      -- boot sequence on screen: the HUD comes in after it
  if not state.visible then
    state.visible = true
    tick_timer:resume()
    if eq.rate then eq.rate(true) end
    fade_to(1)
    render()
  else want() end
  remfx.sync()
  set_section(true)
  arm_hide(secs)
end

local function keep_up()  -- paused, dragging, or the pointer resting on the bar
  if hud.pin or mp.get_property_bool("pause") or state.dragging or state.vdrag or tips_open then return true end
  local m = mp.get_property_native("mouse-pos")
  return m and m.hover and inside(state.panel, m.x, m.y)
end

hide_timer = mp.add_timeout(opts.timeout, function()
  if keep_up() then arm_hide(); return end
  hide()
end)
hide_timer:kill()
tick_timer = mp.add_periodic_timer(0.5, render)   -- keeps the clock / progress moving
tick_timer:kill()
function hud.toggle_pin(v)       -- PIN: frame + bar stay up (living frame); unpin = normal 7 s hide
  if v == nil then hud.pin = not hud.pin else hud.pin = v and true or false end
  if hud.pin then show() else render(); arm_hide() end
  publish()
  return hud.pin
end

-- window size (runs "omaraptor size ...", throttled so a fast wheel doesn't pile up) -----------
local resize_busy, resize_next = false, nil
local function resize(dir)
  if resize_busy then resize_next = dir; return end
  resize_busy = true
  mp.command_native_async({ name = "subprocess", args = { OMARAPTOR, "size", dir },
    playback_only = false, capture_stdout = true, capture_stderr = true }, function()
    resize_busy = false
    local n = resize_next; resize_next = nil
    if n then resize(n) end
  end)
end

-- seeking from the progress bar ----------------------------------------------------------------
local function seek_at(x, exact)
  local dur = mp.get_property_number("duration")
  if not state.buttons.seek or not dur or dur <= 0 then return end
  mp.commandv("seek", tostring(seek_frac(x) * 100), exact and "absolute-percent+exact" or "absolute-percent+keyframes")
  state.last_seek = mp.get_time()
end


-- keyboard panel ("?"): the whole key map in three columns (PLAYBACK / SOUND · VIEW / COCKPIT).
-- Static table: nothing is read from disk when it opens. Esc, ? or a click outside closes it.
local tips = { box = nil, tog = nil }
-- KEY HINTS: the key-letter badges over the buttons on hover. OFF by default; toggled in the "?"
-- panel (click or T) and kept across launches as one tiny file (read once here, written on toggle).
do
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or "") .. "/.local/state" end
  tips.KH_DIR = base .. "/omaraptor"
  tips.KH_FILE = tips.KH_DIR .. "/key-hints"
  local f = io.open(tips.KH_FILE, "r")
  hud.keyhints = f and (f:read("*l") == "on") or false
  if f then f:close() end
end
local ov_tips = mp.create_osd_overlay("ass-events")
ov_tips.z = 30
local function ulen(str) return select(2, str:gsub("[^\128-\191]", "")) end
local KEY_COLS = {
  { "PLAYBACK", {
    { "SPACE / K", "play · pause" }, { "← / →", "back / fwd 5 s" }, { "J / L", "back / fwd 10 s" },
    { "0 – 9", "jump to 0–90 %" }, { "< / >", "speed − / +" }, { "N  ·  ⇧N", "next · previous" },
    { "R", "repeat on / off" } } },
  { "SOUND · VIEW", {
    { "↑ / ↓", "volume ± 5" }, { "M", "mute" }, { "F", "fullscreen" }, { "ESC", "close panel · exit fs" },
    { "-  =  S", "smaller · larger · cycle" }, { "C", "subtitles" }, { "I", "link / signal info" } } },
  { "COCKPIT", {
    { "H", "arm panel (CRUISE ↔ COMBAT)" }, { "ENTER", "throw switch (in panel)" },
    { "O", "new window · paste link" }, { "P", "pin frame + bar" }, { "?", "this panel" }, { "Q", "quit" },
    { "T", "key hints on / off (here)" } } },
}
local KEY_FOOT = "click  play · pause   ·   double-click  fullscreen   ·   drag  move   ·   wheel  volume"

local function render_tips()
  if not tips_open then ov_tips:remove(); return end
  local w, h = mp.get_osd_size()
  if not w or w <= 0 or h <= 0 then return end
  local kch, dch, rows = 0, 0, 0
  for _, c in ipairs(KEY_COLS) do
    rows = math.max(rows, #c[2])
    for _, r in ipairs(c[2]) do kch = math.max(kch, ulen(r[1])); dch = math.max(dch, ulen(r[2])) end
  end
  local margin = math.max(16, math.floor(math.min(w, h) * 0.06))
  local bp = state.visible and state.panel
  local top = bp and bp.by and math.floor(bp.by - bp.fs * 0.9 * 1.45 - 10) or h   -- button row + its key caps stay uncovered
  if top < h * 0.55 then top = h end                 -- too little room above the bar: use the full height (as before)
  local aw, ah = w - 2 * margin, top - margin - math.min(margin, 8)
  -- layout in units of fs: pick 3, 2 or 1 columns, whichever gives the largest type that fits
  local best
  for _, nc in ipairs({ 3, 2, 1 }) do
    local per = nc == 3 and { { 1 }, { 2 }, { 3 } } or nc == 2 and { { 1 }, { 2, 3 } } or { { 1, 2, 3 } }
    local hu = 0
    for _, g in ipairs(per) do
      local u = 0
      for _, ci in ipairs(g) do u = u + 2.6 + #KEY_COLS[ci][2] * 1.95 end
      hu = math.max(hu, u)
    end
    local cwu = (kch + 2) * 0.62 + 2.2 + dch * 0.62 + 1.2   -- keycap + gap + description
    local wu = nc * cwu + (nc - 1) * 2.2 + 3.2
    local hu_all = 3.6 + hu + 2.6
    local fs = math.floor(math.min(aw / wu, ah / hu_all, h * 0.03 + 4))
    if not best or fs > best.fs then best = { fs = fs, nc = nc, per = per, cwu = cwu } end
    if nc == 3 and fs >= 13 then break end
  end
  local fs, nc, per = math.max(8, best.fs), best.nc, best.per
  local cw, gap = math.floor(best.cwu * fs), math.floor(2.2 * fs)
  local head_h, foot_h = math.floor(3.6 * fs), math.floor(2.6 * fs)
  local body_u = 0
  for _, g in ipairs(per) do local u = 0; for _, ci in ipairs(g) do u = u + 2.6 + #KEY_COLS[ci][2] * 1.95 end; body_u = math.max(body_u, u) end
  local pw = math.min(w - 8, math.max(math.floor(aw * 0.84), nc * cw + (nc - 1) * gap + math.floor(3.2 * fs)))
  local ph = math.min(top - 8, head_h + math.floor(body_u * fs) + foot_h)
  local px, py = math.floor((w - pw) / 2), math.max(4, math.floor((top - ph) / 2))
  tips.box = { x = px, y = py, w = pw, h = ph }
  local inner = math.floor(1.6 * fs)
  local colw = math.floor((pw - 2 * inner - (nc - 1) * gap) / nc)
  local bt = math.max(1, math.floor(fs * 0.1 + 0.5))
  local out = {}
  local function ev(body) out[#out + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0" .. body end
  local function rect(x0, y0, x1, y1) return string.format("m %d %d l %d %d l %d %d l %d %d ", x0, y0, x1, y0, x1, y1, x0, y1) end
  local function frame(x, y, fw, fh, t)
    return rect(x, y, x + fw, y + t) .. rect(x, y + fh - t, x + fw, y + fh) ..
      rect(x, y + t, x + t, y + fh - t) .. rect(x + fw - t, y + t, x + fw, y + fh - t)
  end
  local function txt(x, y, an, f, col, al, body, extra)
    out[#out + 1] = string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\q2\\fsp0\\1c&H%s&\\1a&H%02X&%s}%s",
      an, x, y, MONO, f, col, al, extra or "", body)
  end
  ev(string.format("\\1c&H000000&\\1a&H80&\\p1}%s{\\p0}", rect(0, 0, w, top)))               -- dim backdrop (not over the button row)
  ev(string.format("\\1c&H%s&\\1a&H1C&\\p1}%s{\\p0}", INK, rect(px, py, px + pw, py + ph)))
  ev(string.format("\\1c&H%s&\\1a&H30&\\p1}%s{\\p0}", ACCENT, frame(px, py, pw, ph, bt)))
  txt(px + inner, py + math.floor(head_h * 0.5), 4, math.floor(fs * 1.15), ACCENT, 0, "KEYBOARD", "\\b1\\fsp1")
  local hy, cf = py + math.floor(head_h * 0.5), math.floor(fs * 0.8)
  txt(px + pw - inner, hy, 6, cf, AMBER, 0, "?  /  ESC  CLOSE", "\\fsp1")
  do   -- KEY HINTS [ON | OFF] switch, left of CLOSE: two square cells, the live one filled jade
    local ON = hud.keyhints
    local cx1 = px + pw - inner - math.floor(ulen("?  /  ESC  CLOSE") * 0.66 * cf) - math.floor(fs * 1.6)
    local sw, sh = math.floor(fs * 2.6), math.floor(fs * 1.4)
    local lbl = "KEY HINTS"
    local tw = math.floor(fs * 1.4) + math.floor(fs * 0.5) + math.floor(ulen(lbl) * 0.66 * cf) + math.floor(fs * 0.7) + 2 * sw
    if cx1 - tw < px + inner + math.floor(8 * 0.7 * fs * 1.15) + fs then lbl = "HINTS"
      tw = tw - math.floor(4 * 0.66 * cf) end
    local sx0, sy0 = cx1 - 2 * sw, hy - math.floor(sh / 2)
    local cells = { { "ON", sx0, ON }, { "OFF", sx0 + sw, not ON } }
    for _, c in ipairs(cells) do
      if c[3] then ev(string.format("\\1c&H%s&\\1a&H00&\\p1}%s{\\p0}", ACCENT, rect(c[2], sy0, c[2] + sw, sy0 + sh))) end
      ev(string.format("\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}", ACCENT, c[3] and 0x00 or 0x40, frame(c[2], sy0, sw, sh, bt)))
      txt(c[2] + math.floor(sw / 2), hy, 5, cf, c[3] and INK or ACCENT, c[3] and 0 or 0x50, c[1], "\\b1\\fsp1")
    end
    local lx = sx0 - math.floor(fs * 0.7)
    txt(lx, hy, 6, cf, ACCENT, 0, lbl, "\\fsp1")
    local kw = math.floor(fs * 1.4)
    local kx = lx - math.floor(ulen(lbl) * 0.66 * cf) - math.floor(fs * 0.5) - kw
    local fl = tips.flash and mp.get_time() - tips.flash < 0.25   -- just pressed: jade cap, ink letter
    if fl then ev(string.format("\\1c&H%s&\\1a&H00&\\p1}%s{\\p0}", ACCENT, rect(kx, sy0, kx + kw, sy0 + sh))) end
    ev(string.format("\\1c&H%s&\\1a&H10&\\p1}%s{\\p0}", ACCENT, frame(kx, sy0, kw, sh, bt)))
    txt(kx + math.floor(kw / 2), hy, 5, cf, fl and INK or ACCENT, 0, "T", "\\b1")
    tips.tog = { x = kx - 4, y = sy0 - 4, w = cx1 - kx + 8, h = sh + 8 }   -- whole switch (key cap .. OFF) is the hit area
  end
  local caps, lines = {}, {}
  for gi, g in ipairs(per) do
    local x0 = px + inner + (gi - 1) * (colw + gap)
    local y = py + head_h
    for _, ci in ipairs(g) do
      local c = KEY_COLS[ci]
      txt(x0, y + math.floor(fs * 0.8), 4, math.floor(fs * 0.85), AMBER, 0, c[1], "\\b1\\fsp1")
      lines[#lines + 1] = rect(x0, y + math.floor(fs * 1.7), x0 + colw, y + math.floor(fs * 1.7) + 1)
      y = y + math.floor(2.6 * fs)
      local kx = x0
      local dx = x0 + math.floor((kch + 2) * 0.62 * fs + 2.2 * fs)
      for _, r in ipairs(c[2]) do
        local ch = math.floor(fs * 1.5)
        local kw = math.floor(ulen(r[1]) * 0.62 * fs + fs * 1.0)
        local cy = y + math.floor(fs * 0.75)
        caps[#caps + 1] = frame(kx, cy - math.floor(ch / 2), kw, ch, bt)
        txt(kx + math.floor(kw / 2), cy, 5, fs, ACCENT, 0, r[1], "\\b1")
        txt(dx, cy, 4, fs, "E6E6E6", 0x10, r[2])
        y = y + math.floor(1.95 * fs)
      end
    end
  end
  ev(string.format("\\1c&H%s&\\1a&H90&\\p1}%s{\\p0}", ACCENT, table.concat(lines)))
  ev(string.format("\\1c&H%s&\\1a&H10&\\p1}%s{\\p0}", ACCENT, table.concat(caps)))
  txt(px + inner, py + ph - math.floor(foot_h * 0.55), 4, math.floor(fs * 0.75), "AAAAAA", 0x30, KEY_FOOT, "\\fsp1")
  ov_tips.res_x, ov_tips.res_y, ov_tips.data = w, h, table.concat(out, "\n")
  ov_tips:update()
  mp.set_property_native("user-data/omaraptor-hud-tips", { open = true, cols = nc, fs = fs, box = tips.box, tog = tips.tog, keyhints = hud.keyhints })
end

local function close_tips()
  if not tips_open then return end
  tips_open = false
  mp.input_disable_section(TIPS_SECTION)
  ov_tips:remove()
  mp.set_property_native("user-data/omaraptor-hud-tips", { open = false })
  arm_hide()
end
local function open_tips()
  if hud.card_off then hud.card_off() end
  tips_open = true
  local w, h = mp.get_osd_size()
  mp.set_mouse_area(0, 0, w or 10000, h or 10000, TIPS_SECTION)
  mp.input_disable_section(TIPS_SECTION)
  mp.input_enable_section(TIPS_SECTION)   -- on top of the bar, the "?" button and the video click
  show()                                  -- bar first: the panel is laid out above its button row
  render_tips()
end
local function toggle_tips() if tips_open then close_tips() else open_tips() end end
function tips.keyhints_toggle()   -- KEY HINTS on / off: persists as <state>/omaraptor/key-hints ("on"; absent = off)
  hud.keyhints = not hud.keyhints
  tips.flash = mp.get_time()
  if tips_open then render_tips() end            -- feedback first: segment + jade T cap
  show()                                         -- bar up (or kept up); draws it now with the hints on / off
  if tips.flash_t then tips.flash_t:kill() end
  tips.flash_t = mp.add_timeout(0.26, function() tips.flash_t = nil; if tips_open then render_tips() end end)
  local f = io.open(tips.KH_FILE, "w")
  if not f then                                  -- first write only: create the state dir
    mp.command_native({ name = "subprocess", args = { "mkdir", "-p", tips.KH_DIR }, playback_only = false,
      capture_stdout = true, capture_stderr = true })
    f = io.open(tips.KH_FILE, "w")
  end
  if f then f:write(hud.keyhints and "on\n" or "off\n"); f:close() end
  mp.set_property_native("user-data/omaraptor-hud-keyhints", hud.keyhints)
end
local function tips_click(e)
  if e.event ~= "down" and e.event ~= "press" then return end
  local m, b = mp.get_property_native("mouse-pos"), tips.box
  if m and tips.tog and inside(tips.tog, m.x, m.y) then tips.keyhints_toggle(); return end
  if not (m and b and inside(b, m.x, m.y)) then close_tips() end   -- inside: nothing (no pause)
end

-- actions ------------------------------------------------------------------------------------
local actions = {
  back = function() mp.commandv("seek", "-10"); return "-10s" end,
  fwd  = function() mp.commandv("seek", "10"); return "+10s" end,
  play = function()
    mp.commandv("cycle", "pause")
    return mp.get_property_bool("pause") and "PAUSED" or "PLAYING"
  end,
  vol = function()
    mp.commandv("cycle", "mute")
    return mp.get_property_bool("mute") and "Muted" or "Sound on"
  end,
  spd = function(m)                 -- cell = that speed directly; header row = old cycle
    local cur, nxt = mp.get_property_number("speed") or 1, 1
    local i = m and spd_cell_at(state.buttons.spd, m.x, m.y)
    if i then
      if math.abs(SPD_STEPS[i] - cur) < 0.001 then if info_pop then info_pop("spd") end
      else mp.set_property_number("speed", SPD_STEPS[i]) end   -- popup via the speed observer
      return nil
    end
    -- header: 1.00 > 1.25 > 1.50 > 2.00 > 0.75 > 1.00
    for i, v in ipairs(SPEEDS) do if math.abs(v - cur) < 0.01 then nxt = SPEEDS[i % #SPEEDS + 1] end end
    mp.set_property_number("speed", nxt)
    return nil                      -- confirmation = centre popup (speed observer)
  end,
  loop = function(m)                -- OFF / ON halves set it directly; header row toggles
    local r = state.buttons.loop; local h = r and r.halves
    if m and h and m.y >= h.y0 then
      local on = m.x >= h.x0 + h.hw + 2
      if on == ((mp.get_property("loop-file") or "no") ~= "no") then if info_pop then info_pop("loop") end
      else mp.set_property("loop-file", on and "inf" or "no") end
      return nil
    end
    mp.commandv("cycle-values", "loop-file", "inf", "no")
    return nil                      -- confirmation = centre popup (loop-file observer)
  end,
  link = function() if info_pop then info_pop("link") end; return nil end,
  smaller = function() resize("smaller"); return nil end,
  larger  = function() resize("larger"); return nil end,
  help    = function() toggle_tips(); return nil end,
  hud     = function() if arm_toggle then arm_toggle() end; return nil end,
  pin     = function() hud.toggle_pin(); return nil end,
  fs      = function() mp.commandv("cycle", "fullscreen"); return nil end,
  new     = function()   -- another, EMPTY omaraptor window, opened over this one (our pid)
    mp.command_native_async({ name = "subprocess", args = { OMARAPTOR, "new", tostring(mp.get_property_number("pid", 0)) }, playback_only = false,
      detach = true, capture_stdout = false, capture_stderr = false }, function() end)
    return "New window"
  end,
}

local function spd_step(d)                -- wheel on the SPEED box: one cell up / down, clamped
  local cur = mp.get_property_number("speed") or 1
  local i = math.floor((math.max(0.5, math.min(2, cur)) - 0.5) / 0.25 + 0.5) + 1
  local j = math.max(1, math.min(#SPD_STEPS, i + d))
  if j ~= i or math.abs(SPD_STEPS[j] - cur) > 0.001 then mp.set_property_number("speed", SPD_STEPS[j])
  elseif info_pop then info_pop("spd") end
  show()
end
local function vol_at(x)
  local r = state.buttons.vgauge; if not r then return end
  local v = math.max(0, math.min(100, math.floor((x - r.x) / r.w * 20 + 0.5) * 5))
  mp.set_property_number("volume", v)
  if v > 0 and mp.get_property_bool("mute") then mp.set_property_bool("mute", false) end
end
-- drag targets: VOL gauge / VOL tape set volume, TIME tape seeks, heading tape fine-seeks
local function drag_apply(name, m, final)
  local r = state.buttons[name]; if not r or not m then return end
  if name == "vgauge" then vol_at(m.x)
  elseif name == "vtape" then
    if final and state.grab_box and not state.drag_moved then return end      -- click on the box: no change
    local v = math.floor(clamp01((r.y + r.h - (m.y - state.grab_dy)) / r.h) * 100 + 0.5)
    mp.set_property_number("volume", v)
    if v > 0 and mp.get_property_bool("mute") then mp.set_property_bool("mute", false) end
  elseif name == "ttape" then                         -- countdown tape: y = remaining time
    if is_live() then return end                      -- LIVE tape: click jumps to the edge (click())
    if final and state.grab_box and not state.drag_moved then return end
    local dur = mp.get_property_number("duration")
    if not dur or dur <= 0 then return end
    local tgt = dur - clamp01((r.y + r.h - (m.y - state.grab_dy)) / r.h) * dur
    state.seek_tgt = tgt
    if final or mp.get_time() - state.last_seek > 0.06 then
      mp.commandv("seek", tostring(tgt), final and "absolute+exact" or "absolute+keyframes")
      state.last_seek = mp.get_time()
    end
    if info_pop then info_pop("seek") end
  elseif name == "htape" and final then
    local pos, pxs = mp.get_property_number("time-pos"), r.pxs
    if pos and pxs then
      mp.commandv("seek", tostring(math.max(0, pos + (m.x - (r.x + r.w / 2)) / pxs)), "absolute+exact")
    end
  end
end
local function click(e)
  local m = mp.get_property_native("mouse-pos")
  if e.event == "up" then
    if state.vdrag then
      local was = state.vdrag
      drag_apply(was, m, true); state.vdrag = false
      if info_pop and (was == "ttape" or was == "vtape") then info_pop(was == "ttape" and "seek" or "vol") end   -- unpin: hold + fade
      state.grab_dy, state.grab_box, state.seek_tgt = 0, false, nil
      show(); return
    end
    if state.dragging then
      state.dragging = false
      if m then seek_at(m.x, true) end
      show()
    end
    return
  end
  if e.event == "repeat" then return end
  local name = m and hit(m.x, m.y)
  if not name then return end                     -- bar padding: swallow, do nothing
  if name == "ttape" and is_live() then              -- LIVE tape: click = back to the live edge
    if e.event == "down" or e.event == "press" then
      local d = mp.get_property_number("duration")
      if d and d > 0 then mp.commandv("seek", tostring(math.max(0, d - 1)), "absolute") end
      if mp.get_property_bool("pause") then mp.set_property_bool("pause", false) end
      set_status("LIVE EDGE"); show()
    end
    return
  end
  if name == "vgauge" or name == "vtape" or name == "ttape" or name == "htape" then
    state.vdrag = e.event == "down" and name or false
    state.grab_dy, state.grab_box, state.drag_moved = 0, false, false
    if (name == "vtape" or name == "ttape") and e.event == "down" then
      local r = state.buttons[name]
      local by = name == "vtape" and (r.y + r.h - clamp01((mp.get_property_number("volume") or 0) / 100) * r.h)
      if name == "ttape" then
        local dur, pos = mp.get_property_number("duration") or 0, mp.get_property_number("time-pos") or 0
        by = r.y + r.h - (dur > 0 and clamp01((dur - pos) / dur) or 0) * r.h
        state.seek_from, state.seek_tgt = pos, pos
      end
      local bh = math.floor((state.panel and state.panel.fs or 20) * 1.6)
      if math.abs(m.y - by) <= bh * 0.75 then          -- grabbed the pointer box: keep the offset, no jump
        state.grab_dy, state.grab_box = m.y - by, true
      end
      if info_pop then info_pop(name == "ttape" and "seek" or "vol") end   -- pinned while held
      if state.grab_box then show(); return end
    end
    drag_apply(name, m, e.event ~= "down")
  elseif name == "seek" or name == "phead" then         -- the playhead index is the grab target
    state.dragging = e.event == "down"            -- "press" (no up coming): a single seek
    seek_at(m.x, not state.dragging)
  else
    local msg = actions[name](m)
    press_flash(name)
    if msg then set_status(msg:upper()) end
  end
  show()
end

-- Named bindings (no key): the bar's own input section routes the mouse to them.
mp.add_key_binding(nil, "click", click, { complex = true })
mp.add_key_binding(nil, "nop", function() end)
local me = mp.get_script_name()
mp.input_define_section(SECTION,
  "MBTN_LEFT script-binding " .. me .. "/click\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..   -- no fullscreen from a double-tap on the bar
  "MBTN_RIGHT script-binding " .. me .. "/nop\n", "force")
mp.input_define_section(NEW_SECTION,
  "MBTN_LEFT script-binding " .. me .. "/click\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
  "MBTN_RIGHT script-binding " .. me .. "/nop\n", "force")
for _, sec in pairs(TAPES) do
  mp.input_define_section(sec,
    "MBTN_LEFT script-binding " .. me .. "/click\n" ..
    "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
    "MBTN_RIGHT script-binding " .. me .. "/nop\n", "force")
end
mp.add_key_binding(nil, "spd-up", function() spd_step(1) end)
mp.add_key_binding(nil, "spd-down", function() spd_step(-1) end)
mp.input_define_section(TAPES.spd,
  "MBTN_LEFT script-binding " .. me .. "/click\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
  "MBTN_RIGHT script-binding " .. me .. "/nop\n" ..
  "WHEEL_UP script-binding " .. me .. "/spd-up\n" ..
  "WHEEL_DOWN script-binding " .. me .. "/spd-down\n", "force")
mp.input_define_section(HELP_SECTION,
  "MBTN_LEFT script-binding " .. me .. "/click\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
  "MBTN_RIGHT script-binding " .. me .. "/nop\n", "force")
mp.add_key_binding(nil, "tips-click", tips_click, { complex = true })
mp.add_key_binding(nil, "tips-close", close_tips)
mp.add_key_binding(nil, "tips-keyhints", function() tips.keyhints_toggle() end)
mp.set_property_native("user-data/omaraptor-hud-keyhints", hud.keyhints)
mp.input_define_section(TIPS_SECTION,
  "MBTN_LEFT script-binding " .. me .. "/tips-click\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
  "MBTN_RIGHT script-binding " .. me .. "/nop\n" ..
  "ESC script-binding " .. me .. "/tips-close\n" ..
  "? script-binding " .. me .. "/tips-close\n" ..
  "t script-binding " .. me .. "/tips-keyhints\n" ..
  "T script-binding " .. me .. "/tips-keyhints\n" ..
  "WHEEL_UP script-binding " .. me .. "/nop\n" ..
  "WHEEL_DOWN script-binding " .. me .. "/nop\n", "force")
mp.add_key_binding("?", "tips", toggle_tips)
mp.register_event("file-loaded", function() if hud.pin and not state.boot then show() end end)
mp.add_key_binding("p", "pin", function() if hud.card_off then hud.card_off() end; hud.toggle_pin() end)   -- (overrides mpv's default p = pause; Space still pauses)
mp.register_script_message("pin", function(v)   -- IPC: pin yes / no / (toggle)
  if v == "yes" or v == "on" then hud.toggle_pin(true) elseif v == "no" or v == "off" then hud.toggle_pin(false) else hud.toggle_pin() end
end)

-- click on the video (outside the bar) = play / pause ---------------------------------------
-- The built-in drag is off (mpv.conf input-builtin-dragging=no); we start the window drag
-- ourselves once the pointer moves past DRAG_PX while held, so a drag never pauses. A click
-- toggles only after the double-click window passes, so a double-click (fullscreen) leaves
-- the play state alone.
local DRAG_PX = 5 * (mp.get_property_number("display-hidpi-scale") or 1)
local press, click_timer, suppress_up, last_toggle = nil, nil, false, -10
local function dbl_time() return (mp.get_property_number("input-doubleclick-time") or 300) / 1000 end

local function toggle_from_click()
  click_timer = nil
  if state.boot then return end                  -- launcher up: only its FIRE button acts
  mp.commandv("cycle", "pause")
  last_toggle = mp.get_time()
  set_status(mp.get_property_bool("pause") and "PAUSED" or "PLAYING")
  show(1.2)
end
local function arm_click()
  if click_timer then click_timer:kill() end
  click_timer = mp.add_timeout(dbl_time(), toggle_from_click)
end

local function video_click(e)
  local m = mp.get_property_native("mouse-pos") or { x = 0, y = 0 }
  local w, h = mp.get_osd_size()
  if e.event == "down" then
    press = { x = m.x, y = m.y, t = mp.get_time(), w = w, h = h }
  elseif e.event == "up" then
    local p = press; press = nil
    if suppress_up then suppress_up = false; return end
    if not p then return end                      -- dragged (or the press started elsewhere)
    if math.abs(m.x - p.x) > DRAG_PX or math.abs(m.y - p.y) > DRAG_PX then return end
    if w ~= p.w or h ~= p.h or mp.get_time() - p.t > 0.6 then return end  -- edge resize / long hold
    arm_click()
  elseif e.event == "press" then                  -- synthetic (IPC keypress): no down/up pair
    arm_click()
  end
end

local function video_dbl()
  if click_timer then click_timer:kill(); click_timer = nil      -- first click never applied
  elseif mp.get_time() - last_toggle < dbl_time() + 0.15 then      -- it slipped through: undo
    mp.commandv("cycle", "pause")
  end
  if press then suppress_up = true end           -- the second release isn't a new click
  mp.commandv("cycle", "fullscreen")
end

local function video_drag_check(m)  -- called on every pointer move
  if press and (math.abs(m.x - press.x) > DRAG_PX or math.abs(m.y - press.y) > DRAG_PX) then
    press = nil
    if mp.get_property_bool("fullscreen") ~= true then mp.commandv("begin-vo-dragging") end
  end
end

mp.add_key_binding("MBTN_LEFT", "video-click", video_click, { complex = true })
mp.add_key_binding("MBTN_LEFT_DBL", "video-dbl", video_dbl)
mp.register_script_message("omaraptor-test-geom", function()   -- dev: button rects for click tests
  local out = {}
  for k, r in pairs(state.buttons or {}) do out[k] = { x = r.x, y = r.y, w = r.w, h = r.h } end
  mp.set_property("user-data/ytf-geom", utils.format_json(out))
end)
mp.register_script_message("omaraptor-tape-sim", function(name, act, fy)   -- dev: tape hover/drag self-test
  local r = state.buttons[name]; if not r then return end
  local y = (fy == "box") and nil or (r.y + r.h - (tonumber(fy) or 0.5) * r.h)
  if not y then                                    -- "box": the pointer box centre
    if name == "vtape" then y = r.y + r.h - clamp01((mp.get_property_number("volume") or 0) / 100) * r.h
    else
      local dur, pos = mp.get_property_number("duration") or 1, mp.get_property_number("time-pos") or 0
      y = r.y + r.h - clamp01((dur - pos) / dur) * r.h
    end
  end
  local m = { x = name == "vtape" and r.x + r.w + 30 or r.x - 30, y = math.floor(y), hover = true }
  state.mx, state.my = m.x, m.y
  if act == "hover" then state.hot = name; show(60); render()
  elseif act == "down" then
    state.hot = name
    local real = mp.get_property_native
    mp.get_property_native = function(p, d) if p == "mouse-pos" then return m end return real(p, d) end
    click({ event = "down" }); mp.get_property_native = real
  elseif act == "move" then
    if state.vdrag then state.drag_moved = true; drag_apply(state.vdrag, m, false); render() end
  elseif act == "up" then
    local real = mp.get_property_native
    mp.get_property_native = function(p, d) if p == "mouse-pos" then return m end return real(p, d) end
    click({ event = "up" }); mp.get_property_native = real
  end
end)
mp.register_script_message("omaraptor-test-click", function(kind)  -- IPC self-test hooks
  if kind == "dbl" then video_dbl() else video_click({ event = "press" }) end
end)

mp.observe_property("mouse-pos", "native", function(_, m)
  if not m then return end
  video_drag_check(m)
  state.mx, state.my, state.mhover = m.x, m.y, m.hover
  if state.vdrag then state.drag_moved = true; drag_apply(state.vdrag, m, false); render(); return end
  if state.dragging then
    if mp.get_time() - state.last_seek > 0.06 then seek_at(m.x, false) end
    render()
    return
  end
  if not m.hover then
    if state.visible and not hud.pin and not mp.get_property_bool("pause") then hide() end
    state.hot = nil
    if state.visible then render() end
    return
  end
  state.hot = hit(m.x, m.y)
  show()
end)

local function refresh() if state.visible or state.fade > 0 then render() end end
mp.add_timeout(1.5, function() fpm.ready = true end)
local function fpm_flash(paused)
  if style ~= "f22" or not fpm.ready or hud.light then return end
  fpm.t, fpm.paused = mp.get_time(), paused
  if fpm.timer then fpm.timer:kill() end
  fpm.timer = mp.add_periodic_timer(1 / 30, function()
    if mp.get_time() - fpm.t > 2.7 then
      fpm.timer:kill(); fpm.timer = nil
    end
    want()
  end)
end
mp.observe_property("pause", "bool", function(_, paused)
  fpm_flash(paused)
  remfx.sync()
  if paused then show() else refresh(); if state.visible then arm_hide() end end
end)
-- volume graphic: transient digital meter on any volume / mute change -----------------------
-- 20 square segments (5 % each, jade lit / dim grey), big neon "VOL 080" or "MUTED", HUD brackets.
-- Instant on, holds 0.8 s after the last change, fades out over 0.3 s. mpv's own volume OSD is
-- silenced with no-osd in input.conf so the two never double up.
local vol_ov = mp.create_osd_overlay("ass-events")
vol_ov.z = 25
local volfx = { fade = 0, hold = nil, timer = nil, ready = false, pin = false, kind = "vol" }
local AMBER_CORE = "C8E6F0"        -- pale amber neon core (#F0E6C8)
local function draw_vol()
  local w, h = mp.get_osd_size()
  if not w or w <= 0 or volfx.fade <= 0 then vol_ov:remove(); return end
  local saved = state.fade; state.fade = volfx.fade      -- reuse a() / neon() with our own fade
  local muted, vol = mp.get_property_bool("mute"), mp.get_property_number("volume") or 0
  local u = math.floor(math.max(20, math.min(38, h * 0.075)) * opts.size + 0.5)
  if style == "f22" and mp.get_property_bool("fullscreen") then
    u = math.floor(math.max(28, math.min(62, h * 0.030)) * opts.size + 0.5)          -- FS: fits between heading tape and scope rings
  end
  local N = 20
  local seg = math.max(7, math.floor(math.min(w * 0.6, u * 12) / N * 0.78))
  local sg = math.max(2, math.floor(seg * 0.28))
  local mw = N * seg + (N - 1) * sg
  local pad = math.floor(u * 0.45)
  local big = math.floor(u * 0.95)
  local pw, ph = mw + 2 * pad, pad + big + math.floor(u * 0.35) + seg + pad
  -- upper band: clear of the top strip / heading tape and above the centre scope + lock rings
  local x0, y0 = math.floor((w - pw) / 2), math.floor(h * ((style == "f22" and mp.get_property_bool("fullscreen")) and 0.264 or 0.235) - ph / 2)
  local ass = assdraw.ass_new()
  if volfx.kind ~= "vol" then                        -- SPD / LOOP / BUFFER: same popup, amber frame
    local kind = volfx.kind
    local bigt, lt, rt, M, lit2
    local FC, FCORE = AMBER, AMBER_CORE
    if kind == "seek" then                            -- REM tape drag: jade seek stamp, target + delta
      local dur = mp.get_property_number("duration") or 0
      local tgt = state.seek_tgt or mp.get_property_number("time-pos") or 0
      local d = tgt - (state.seek_from or tgt)
      local ad = math.floor(math.abs(d) + 0.5)
      FC, FCORE = ACCENT, nil
      local i = math.floor(tgt)
      bigt = (i >= 3600 and string.format("%d:%02d:%02d", math.floor(i / 3600), math.floor(i / 60) % 60, i % 60)
        or string.format("%02d:%02d", math.floor(i / 60), i % 60)) .. string.format(".%03d", math.floor((tgt - i) * 1000))
      lt = string.format("SEEK  T-%s", dtime(math.max(0, dur - tgt)))
      rt = string.format("%s%02d:%02d", d < 0 and "-" or "+", math.floor(ad / 60), ad % 60)
      M, lit2 = 20, dur > 0 and math.max(0, math.min(20, math.floor(tgt / dur * 20 + 0.5))) or 0
    elseif kind == "spd" then
      local sp = mp.get_property_number("speed") or 1
      bigt = string.format("SPD %.2fx", sp); lt = "SPEED"
      rt = math.abs(sp - 1) < 0.001 and "NORM" or (sp > 1 and "FAST" or "SLOW")
      M, lit2 = 16, math.max(0, math.min(16, math.floor(sp / 2 * 16 + 0.5)))       -- 0 .. 2.00x, 0.125x a cell
    elseif kind == "hud" then
      bigt = hud.light and "CRUISE MODE" or "COMBAT MODE"; lt = "HUD"; rt = hud.light and "MIN" or "MAX"
      M, lit2 = 2, hud.light and 1 or 2
    elseif kind == "loop" then
      local on = (mp.get_property("loop-file") or "no") ~= "no"
      bigt = on and "LOOP ON" or "LOOP OFF"; lt = "REPEAT"; rt = on and "FILE" or "ONCE"
      M, lit2 = 2, on and 2 or 1                                                    -- two-cell switch: OFF | ON
    else
      local net = mp.get_property_bool("demuxer-via-network")
      local c = mp.get_property_number("demuxer-cache-duration") or 0
      local stall = mp.get_property_bool("paused-for-cache")
      bigt = not net and "BUFFER LOCAL" or (stall and "BUFFERING" or string.format("BUFFER %02ds", math.min(99, math.floor(c))))
      lt = "LINK"; rt = net and "NET" or "FILE"
      M, lit2 = 20, net and math.max(0, math.min(20, math.floor(c / 3 + 0.5))) or 20   -- 0 .. 60 s, 3 s a cell
    end
    shape(ass, INK, 0x38, function(d) d:rect_cw(x0, y0, x0 + pw, y0 + ph) end)
    shape(ass, "FFFFFF", 0xF6, function(d) for y = y0 + 2, y0 + ph - 2, 3 do d:rect_cw(x0 + 1, y, x0 + pw - 1, y + 1) end end)
    shape(ass, FC, 0x40, function(d) outline(d, x0, y0, pw, ph, 1) end)
    shape(ass, FC, 0x00, function(d) ticks(d, x0, y0, pw, ph, 2, math.floor(u * 0.5)) end)
    local ry = y0 + pad + math.floor(big / 2)
    local fs = math.max(10, math.floor(u * 0.48 + 0.5))
    mtext(ass, x0 + pad, ry, math.floor(fs * 0.9), "FFFFFF", 0x58, lt, 4, "\\fsp3")
    mtext(ass, x0 + pw - pad, ry, math.floor(fs * 0.9), FC, 0x10, rt, 6, "\\fsp3")
    neon(ass, math.floor(w / 2), ry, big, bigt, 5, "", nil, FC, FCORE)
    local sy = y0 + ph - pad - seg
    local cw = math.floor((mw - (M - 1) * sg) / M)
    local function cell(i) local x = x0 + pad + (i - 1) * (cw + sg); return x, x + cw end
    if kind == "loop" or kind == "hud" then         -- switch: the active half lit, the other dim
      for i = 1, 2 do
        local xa, xb = cell(i)
        local on = i == lit2
        shape(ass, on and FC or "FFFFFF", on and 0x00 or 0xC8, function(d) d:rect_cw(xa, sy, xb, sy + seg) end)
        mtext(ass, (xa + xb) / 2, sy + seg / 2, math.max(7, math.floor(seg * 0.8)), on and INK or "FFFFFF", on and 0x00 or 0x60,
          kind == "hud" and (i == 1 and "CRUISE" or "COMBAT") or (i == 1 and "OFF" or "ON"), 5, "\\fsp2")
      end
    else
      shape(ass, "FFFFFF", 0xC8, function(d) for i = lit2 + 1, M do local xa, xb = cell(i); d:rect_cw(xa, sy, xb, sy + seg) end end)
      if lit2 > 0 then
        local _, xe = cell(lit2)
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\shad0\\bord%d\\blur%d\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&}",
          math.floor(seg * 0.35), math.floor(seg * 0.6), FC, FC, a(0x90), a(0xC0)))
        ass:draw_start(); ass:rect_cw(x0 + pad, sy, xe, sy + seg); ass:draw_stop()
        shape(ass, FC, 0x00, function(d) for i = 1, lit2 do local xa, xb = cell(i); d:rect_cw(xa, sy, xb, sy + seg) end end)
      end
      if kind == "spd" then                          -- 1.00x reference notch above the meter
        local _, xn = cell(8)
        shape(ass, "FFFFFF", 0x30, function(d) d:rect_cw(xn + sg / 2 - 1, sy - math.floor(seg * 0.5), xn + sg / 2 + 1, sy - 2) end)
      end
    end
    state.fade = saved
    vol_ov.res_x, vol_ov.res_y, vol_ov.data = w, h, ass.text
    vol_ov:update()
    return
  end
  shape(ass, INK, 0x38, function(d) d:rect_cw(x0, y0, x0 + pw, y0 + ph) end)
  shape(ass, "FFFFFF", 0xF6, function(d)
    for y = y0 + 2, y0 + ph - 2, 3 do d:rect_cw(x0 + 1, y, x0 + pw - 1, y + 1) end
  end)
  shape(ass, "FFFFFF", 0xB8, function(d) outline(d, x0, y0, pw, ph, 1) end)
  local MC = muted and RUST or ACCENT
  shape(ass, MC, 0x00, function(d) ticks(d, x0, y0, pw, ph, 2, math.floor(u * 0.5)) end)
  local ry = y0 + pad + math.floor(big / 2)
  local fs = math.max(10, math.floor(u * 0.48 + 0.5))
  mtext(ass, x0 + pad, ry, math.floor(fs * 0.9), "FFFFFF", 0x58, muted and "AUDIO" or "VOL", 4, "\\fsp3")
  mtext(ass, x0 + pw - pad, ry, math.floor(fs * 0.9), muted and RUST or "FFFFFF", muted and 0x00 or 0x58,
    muted and "OFF" or (vol > 100 and "BOOST" or "%"), 6, "\\fsp3")
  local txt = muted and "MUTED" or string.format("VOL %03d", math.floor(vol + 0.5))
  if muted then neon(ass, math.floor(w / 2), ry, big, txt, 5, "", nil, RUST, RUST_CORE)
  else neon(ass, math.floor(w / 2), ry, big, txt, 5, "") end
  local lit = muted and 0 or math.min(N, math.floor(vol / (100 / N) + 0.5))
  local sy = y0 + ph - pad - seg
  shape(ass, "FFFFFF", 0xC8, function(d)             -- dim grey segments
    for i = lit + 1, N do local x = x0 + pad + (i - 1) * (seg + sg); d:rect_cw(x, sy, x + seg, sy + seg) end
  end)
  if muted then                                      -- muted: the kept level as jade outlines, struck through
    local ml = math.min(N, math.floor(vol / (100 / N) + 0.5))
    shape(ass, RUST, 0x40, function(d)
      for i = 1, ml do local x = x0 + pad + (i - 1) * (seg + sg); outline(d, x, sy, seg, seg, 1) end
    end)
    shape(ass, RUST, 0x20, function(d) d:rect_cw(x0 + pad, sy + math.floor(seg / 2), x0 + pad + mw, sy + math.floor(seg / 2) + 1) end)
  elseif lit > 0 then
    local xe = x0 + pad + lit * (seg + sg) - sg
    ass:new_event()                                  -- glow under the lit run
    ass:append(string.format("{\\an7\\pos(0,0)\\shad0\\bord%d\\blur%d\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&}",
      math.floor(seg * 0.35), math.floor(seg * 0.6), ACCENT, ACCENT, a(0x80), a(0xB0)))
    ass:draw_start(); ass:rect_cw(x0 + pad, sy, xe, sy + seg); ass:draw_stop()
    shape(ass, ACCENT, 0x00, function(d)
      for i = 1, lit do local x = x0 + pad + (i - 1) * (seg + sg); d:rect_cw(x, sy, x + seg, sy + seg) end
    end)
  end
  state.fade = saved
  vol_ov.res_x, vol_ov.res_y, vol_ov.data = w, h, ass.text
  vol_ov:update()
end
local function vol_kill() if volfx.timer then volfx.timer:kill(); volfx.timer = nil end end
local function vol_pop(kind)
  if not volfx.ready or idle_empty_now() then return end
  volfx.kind = kind or "vol"
  vol_kill(); if volfx.hold then volfx.hold:kill() end
  volfx.fade = 1; draw_vol()
  if volfx.pin or state.vdrag == "vtape" or state.vdrag == "ttape" then return end   -- held while dragging
  volfx.hold = mp.add_timeout(0.8, function()
    local t0 = mp.get_time()
    volfx.timer = mp.add_periodic_timer(1 / 30, function()
      volfx.fade = math.max(0, 1 - (mp.get_time() - t0) / 0.3)
      draw_vol()
      if volfx.fade <= 0 then vol_kill(); vol_ov:remove() end
    end)
  end)
end
mp.add_timeout(1.5, function() volfx.ready = true end)   -- not for the startup values
mp.observe_property("mute", "bool", function() refresh(); vol_pop() end)
mp.observe_property("fullscreen", "bool", function(...) refresh(...); remfx.sync() end)   -- swaps the fullscreen button icon; LIVE tape clock
mp.observe_property("volume", "number", function() refresh(); vol_pop() end)
mp.observe_property("duration", "number", refresh)
mp.observe_property("speed", "number", function() refresh(); vol_pop("spd") end)
mp.observe_property("loop-file", "native", function() refresh(); vol_pop("loop") end)
mp.observe_property("paused-for-cache", "bool", function(_, v) if v then vol_pop("link") end end)   -- stall: BUFFERING
info_pop = function(kind) vol_pop(kind) end

-- audio signal meter feed ----------------------------------------------------------------------
-- astats on a labelled af (added at load, never touches mpv.conf); reset=3 ~ 60 ms windows.
local EQ_AF = "@ytfeq:lavfi=[astats=metadata=1:reset=2:measure_perchannel=Peak_level:measure_overall=RMS_level]"
local EQ_DROP = true                 -- LIGHT removes the astats filter (restored on FULL)
local function eq_has_af()
  for _, f in ipairs(mp.get_property_native("af") or {}) do if f.label == "ytfeq" then return true end end
  return false
end
if opts.eq and not (hud.light and EQ_DROP) and not eq_has_af() then mp.commandv("af", "add", EQ_AF) end
local function eq_db(v) v = tonumber(v); if not v or v ~= v or v < -90 then return -90 end; return v end
local function linkh_tick(now)
  if now - linkh.t < 0.24 then return false end
  linkh.t = now
  local c = mp.get_property_bool("demuxer-via-network") and (mp.get_property_number("demuxer-cache-duration") or 0) or 60
  linkh[#linkh + 1] = c
  if #linkh > 120 then table.remove(linkh, 1) end
  return true
end
local function eq_tick()
  local now = mp.get_time()
  if not state.visible and state.fade <= 0 then linkh_tick(now); return end
  local dt = eq.t > 0 and math.min(0.2, now - eq.t) or 0; eq.t = now
  local md = mp.get_property_native("af-metadata/ytfeq")
  local audio = mp.get_property_native("current-tracks/audio") ~= nil
  local idle = mp.get_property_bool("pause") or mp.get_property_bool("paused-for-cache")   -- mute: keeps measuring (pre-mute af)
  eq.have = audio and (eq.have or (md ~= nil and next(md) ~= nil))
  local tgt = { -90, -90, -90 }
  if md and not idle then
    local l = eq_db(md["lavfi.astats.1.Peak_level"])
    local r2 = md["lavfi.astats.2.Peak_level"] and eq_db(md["lavfi.astats.2.Peak_level"]) or l
    tgt = { l, r2, eq_db(md["lavfi.astats.Overall.RMS_level"]) }
  end
  local busy = false
  for i = 1, 3 do
    if tgt[i] >= eq.lv[i] then eq.lv[i] = tgt[i] else eq.lv[i] = math.max(tgt[i], eq.lv[i] - 54 * dt) end
    if eq.lv[i] >= eq.pk[i] then eq.pk[i], eq.pkt[i] = eq.lv[i], now
    elseif now - eq.pkt[i] > 0.6 then eq.pk[i] = math.max(-90, eq.pk[i] - 30 * dt) end
    if eq.pk[i] > -43 then busy = true end
  end
  local lk_new = linkh_tick(now)
  if state.fade > 0 and state.panel and ((busy or eq.was_busy) and state.panel.eq or (lk_new and state.panel.rhero)) then want() end
  eq.was_busy = busy
end
-- 25 Hz while the bar is up; hidden: 4 Hz, BUFFER history only (no meter / property churn)
if opts.eq then eq.timer = mp.add_periodic_timer(1 / 25, eq_tick) end
function eq.rate(up)
  if not eq.timer then return end
  if hud.light then eq.timer:kill(); return end      -- LIGHT: no meter, no BUFFER history
  local want_t = up and 1 / 25 or 0.25
  if eq.timer.timeout ~= want_t or not eq.timer:is_enabled() then
    eq.timer:kill(); eq.timer.timeout = want_t; eq.t = 0; eq.timer:resume()
  end
end
eq.rate(state.visible)
set_light = function(on, pop)
  on = on and true or false
  local changed = on ~= hud.light
  hud.light = on
  if on then
    if fpm.timer then fpm.timer:kill(); fpm.timer = nil end
    marquee_run(false)
    eq.have = false
    if opts.eq and EQ_DROP and eq_has_af() then mp.commandv("af", "remove", "@ytfeq") end
  elseif opts.eq and EQ_DROP and not eq_has_af() then mp.commandv("af", "add", EQ_AF) end
  eq.rate(state.visible)
  remfx.sync()
  hud.tkey = nil
  mp.set_property_native("user-data/omaraptor-hud-mode", on and "light" or "full")
  if changed or pop then
    if state.visible then render(); set_section(true) else refresh() end
  end
  if pop and info_pop then info_pop("hud") end
end
mp.set_property_native("user-data/omaraptor-hud-mode", hud.light and "light" or "full")
-- MASTER ARM / STAND DOWN panel ------------------------------------------------------------
-- H or the HUD tile opens it. CRUISE -> COMBAT: guarded switch (click 1 lifts the guard, click 2 /
-- drag up flips it), "COMBAT MODE ENGAGED", HUD powers on staggered over 0.5 s. COMBAT -> CRUISE:
-- single toggle, "CRUISE MODE". Enter confirms; Esc / H / click outside / 5 s cancels.
-- Timers exist only while the panel or its flash / power-on runs.
do
local ARM_SECTION = "omaraptor-hud-arm"
local arm_ov = mp.create_osd_overlay("ass-events")
arm_ov.z = 30
local arm = { open = false }
local function arm_kill()
  for _, k in ipairs({ "to", "ft", "bt", "dt" }) do if arm[k] then arm[k]:kill(); arm[k] = nil end end
end
local function arm_geom(w, h)
  local u = math.floor(math.max(20, math.min(38, h * 0.075)) * opts.size + 0.5)
  if mp.get_property_bool("fullscreen") then u = math.floor(math.max(28, math.min(62, h * 0.030)) * opts.size + 0.5) end
  local pw, ph = math.floor(u * 10), math.floor(u * 7.4)
  local g = { u = u, x = math.floor((w - pw) / 2), y = math.floor((h - ph) / 2), w = pw, h = ph }
  local sw, sh = math.floor(u * 1.5), math.floor(u * 2.3)
  g.sw = { x = math.floor((w - sw) / 2), y = g.y + math.floor(u * 1.55), w = sw, h = sh }
  local gp = math.max(3, math.floor(u * 0.14))
  g.gd = { x = g.sw.x - gp, y = g.sw.y - gp, w = sw + 2 * gp, h = sh + 2 * gp }       -- closed guard cover
  return g
end
local function draw_arm()
  local w, h = mp.get_osd_size()
  if not arm.open or not w or w <= 0 then arm_ov:remove(); return end
  local saved = state.fade; state.fade = 1
  local g = arm_geom(w, h); arm.g = g
  local u, x0, y0, pw, ph = g.u, g.x, g.y, g.w, g.h
  local pad, fs = math.floor(u * 0.45), math.max(10, math.floor(u * 0.42 + 0.5))
  local ass = assdraw.ass_new()
  local combat = arm.target == "combat"
  shape(ass, INK, 0x28, function(d) d:rect_cw(x0, y0, x0 + pw, y0 + ph) end)
  shape(ass, "FFFFFF", 0xF6, function(d) for y = y0 + 2, y0 + ph - 2, 3 do d:rect_cw(x0 + 1, y, x0 + pw - 1, y + 1) end end)
  shape(ass, AMBER, 0x40, function(d) outline(d, x0, y0, pw, ph, 1) end)
  shape(ass, AMBER, 0x00, function(d) ticks(d, x0, y0, pw, ph, 2, math.floor(u * 0.5)) end)
  local hy = y0 + pad + math.floor(fs * 0.5)
  mtext(ass, x0 + pad, hy, fs, "FFFFFF", 0x58, combat and "ARM PANEL" or "HUD PANEL", 4, "\\fsp3")
  mtext(ass, x0 + pw - pad, hy, fs, AMBER, 0x10, combat and "CRUISE > COMBAT" or "COMBAT > CRUISE", 6, "\\fsp2")
  shape(ass, AMBER, 0xA0, function(d) d:rect_cw(x0 + pad, hy + fs, x0 + pw - pad, hy + fs + 1) end)
  local r, up = g.sw, arm.flipped
  if combat then up = arm.flipped else up = not arm.flipped end            -- STAND DOWN starts armed (up)
  -- side lamps: SAFE (lever down) | ARM (lever up)
  local lq = math.floor(u * 0.32)
  local function lamp(cx, txt, on, col)
    local ly = r.y + math.floor(r.h / 2)
    shape(ass, on and col or "FFFFFF", on and 0x00 or 0xB0, function(d) d:rect_cw(cx - lq / 2, ly - lq - 2, cx + lq / 2, ly - 2) end)
    mtext(ass, cx, ly + math.floor(fs * 0.7), math.floor(fs * 0.85), on and col or "FFFFFF", on and 0x00 or 0x70, txt, 5, "\\fsp2")
  end
  lamp(r.x - math.floor(u * 1.5), "SAFE", not up, ACCENT)
  lamp(r.x + r.w + math.floor(u * 1.5), "ARM", up, AMBER)
  -- switch housing, slot, lever (square knob on a shaft)
  shape(ass, INK, 0x00, function(d) d:rect_cw(r.x, r.y, r.x + r.w, r.y + r.h) end)
  shape(ass, "FFFFFF", 0x60, function(d) outline(d, r.x, r.y, r.w, r.h, 1) end)
  local sx, slw = math.floor(r.x + r.w / 2), math.max(3, math.floor(r.w * 0.16))
  local m = math.floor(r.h * 0.12)
  shape(ass, "FFFFFF", 0xC8, function(d) d:rect_cw(sx - slw, r.y + m, sx + slw, r.y + r.h - m) end)
  local kq = math.floor(r.w * 0.56)
  local ky = up and (r.y + m) or (r.y + r.h - m - kq)
  local kc = up and AMBER or ACCENT
  shape(ass, kc, 0x50, function(d) d:rect_cw(sx - 1, math.floor(r.y + r.h / 2), sx + 2, ky + (up and kq or 0)) end)
  shape(ass, kc, 0x00, function(d) d:rect_cw(sx - kq / 2, ky, sx + kq / 2, ky + kq) end, 1, INK, 0x00)
  shape(ass, INK, 0x30, function(d) for i = 1, 3 do local y = ky + math.floor(kq * i / 4); d:rect_cw(sx - kq / 2 + 3, y, sx + kq / 2 - 3, y + 1) end end)
  -- guard cover (COMBAT only): closed = hazard plate over the switch; open = flipped up above it
  if combat then
    local gd = g.gd
    if not arm.guard then
      shape(ass, AMBER, 0x30, function(d) d:rect_cw(gd.x, gd.y, gd.x + gd.w, gd.y + gd.h) end)
      local st = math.max(3, math.floor(gd.h / 9))
      shape(ass, INK, 0x10, function(d) for y = gd.y + st, gd.y + gd.h - st, 2 * st do d:rect_cw(gd.x + 2, y, gd.x + gd.w - 2, y + st) end end)
      shape(ass, AMBER, 0x00, function(d) outline(d, gd.x, gd.y, gd.w, gd.h, 2) end)
      local tw = math.floor(fs * 3.6)
      shape(ass, INK, 0x00, function(d) d:rect_cw(gd.x + gd.w / 2 - tw / 2, gd.y + gd.h / 2 - fs * 0.7, gd.x + gd.w / 2 + tw / 2, gd.y + gd.h / 2 + fs * 0.7) end)
      mtext(ass, math.floor(gd.x + gd.w / 2), math.floor(gd.y + gd.h / 2), math.floor(fs * 0.9), AMBER, 0x00, "GUARD", 5, "\\b1\\fsp2")
    else
      local th = math.max(4, math.floor(u * 0.26))
      local gy = gd.y - th - math.floor(u * 0.12)
      shape(ass, AMBER, 0x30, function(d) d:rect_cw(gd.x, gy, gd.x + gd.w, gy + th) end)
      shape(ass, INK, 0x10, function(d) local st = math.max(3, math.floor(gd.w / 9))
        for x = gd.x + st, gd.x + gd.w - st, 2 * st do d:rect_cw(x, gy + 1, x + st, gy + th - 1) end end)
      shape(ass, AMBER, 0x00, function(d) outline(d, gd.x, gy, gd.w, th, 1); d:rect_cw(gd.x, gd.y - 2, gd.x + gd.w, gd.y) end)  -- plate + hinge
    end
  end
  -- title / flash / hint
  local ty = r.y + r.h + math.floor(u * 0.95)
  local fl = arm.flash
  if fl then
    local t = mp.get_time() - fl.t0
    local vis = t > 0.45 or math.floor(t * 10) % 2 == 0                 -- 2 quick blinks, then steady
    if vis then neon(ass, math.floor(w / 2), ty, math.floor(u * 0.66), fl.txt, 5, "", nil, ACCENT) end
    mtext(ass, math.floor(w / 2), y0 + ph - pad, math.floor(fs * 0.85), "FFFFFF", 0x50, fl.sub, 2, "\\fsp2")
  else
    neon(ass, math.floor(w / 2), ty, math.floor(u * 0.78), combat and "MASTER ARM" or "STAND DOWN", 5, "", nil, AMBER, "C8E6F0")
    local hint = combat and (arm.guard and "CLICK / DRAG UP: ARM  ·  ESC" or "CLICK: LIFT GUARD  ·  ENTER  ·  ESC")
      or "CLICK: SAFE  ·  ENTER  ·  ESC"
    mtext(ass, math.floor(w / 2), y0 + ph - pad, math.floor(fs * 0.85), "FFFFFF", 0x50, hint, 2, "\\fsp2")
  end
  state.fade = saved
  arm_ov.res_x, arm_ov.res_y, arm_ov.data = w, h, ass.text
  arm_ov:update()
  mp.set_property_native("user-data/omaraptor-hud-arm", { open = true, target = arm.target, guard = arm.guard or false,
    flipped = arm.flipped or false, flash = fl and fl.txt or "", sw = g.sw, guard_box = g.gd,
    panel = { x = g.x, y = g.y, w = g.w, h = g.h } })
end
local function arm_close()
  if not arm.open then return end
  arm_kill(); arm.open = false; arm.flash = nil
  mp.input_disable_section(ARM_SECTION)
  arm_ov:remove()
  mp.set_property_native("user-data/omaraptor-hud-arm", { open = false })
end
local function arm_rearm()            -- 5 s inactivity cancels (not once the switch is thrown)
  if arm.to then arm.to:kill() end
  arm.to = mp.add_timeout(5, function() arm.to = nil; if not arm.flipped then arm_close() end end)
end
local function power_on()             -- COMBAT: staggered power-on, ~0.5 s, then the scope's intro blink
  hud.boot = mp.get_time()
  if arm.bt then arm.bt:kill() end
  arm.bt = mp.add_periodic_timer(1 / 30, function()
    if mp.get_time() - hud.boot >= 0.5 then
      arm.bt:kill(); arm.bt = nil; hud.boot = nil
      fpm_flash(mp.get_property_bool("pause"))
    end
    if state.visible or state.fade > 0 then want() end
  end)
end
local function arm_flip()
  if arm.flipped then return end
  arm.flipped = true
  if arm.to then arm.to:kill(); arm.to = nil end
  local combat = arm.target == "combat"
  arm.flash = { t0 = mp.get_time(), txt = combat and "COMBAT MODE ENGAGED" or "CRUISE MODE",
    sub = combat and "HUD POWER ON" or "HUD STRIPPED  ·  LOW POWER" }
  if combat then set_light(false, false); power_on() else set_light(true, false) end
  show()
  draw_arm()
  arm.ft = mp.add_periodic_timer(1 / 20, function()                -- flash, then the panel closes
    local t = mp.get_time() - arm.flash.t0
    if t >= 0.95 then arm_close() else draw_arm() end
  end)
end
local function arm_open()
  if hud.card_off then hud.card_off() end
  arm_kill()
  arm.open, arm.target, arm.guard, arm.flipped, arm.flash = true, hud.light and "combat" or "cruise", false, false, nil
  local w, h = mp.get_osd_size()
  mp.set_mouse_area(0, 0, w or 10000, h or 10000, ARM_SECTION)
  mp.input_disable_section(ARM_SECTION); mp.input_enable_section(ARM_SECTION)   -- on top of bar / tips / video
  arm_rearm(); show(); draw_arm()
end
arm_toggle = function() if arm.open then arm_close() else arm_open() end end
local function arm_enter()
  if not arm.open or arm.flipped then return end
  if arm.target == "combat" and not arm.guard then
    arm.guard = true; draw_arm()
    arm.dt = mp.add_timeout(0.18, function() arm.dt = nil; arm_flip() end)   -- guard up, then the switch
  else arm_flip() end
end
local function arm_press(x, y)
  if not arm.open or arm.flipped or not arm.g then return end
  local g, pad = arm.g, math.floor(arm.g.u * 0.3)
  local function within(r) return x >= r.x - pad and x < r.x + r.w + pad and y >= r.y - pad * 2 and y < r.y + r.h + pad end
  if not inside(g, x, y) then arm_close(); return end                  -- click outside: cancel
  arm_rearm()
  if arm.target == "combat" and not arm.guard then
    if within(g.gd) then arm.guard = true; draw_arm() end
  elseif within(g.sw) then arm_flip() end                               -- press (or the start of a drag up) flips
end
mp.add_key_binding(nil, "arm-click", function(e)
  if e.event ~= "down" and e.event ~= "press" then return end
  local m = mp.get_property_native("mouse-pos")
  if m then arm_press(m.x, m.y) end
end, { complex = true })
mp.add_key_binding(nil, "arm-cancel", arm_close)
mp.add_key_binding(nil, "arm-enter", arm_enter)
mp.input_define_section(ARM_SECTION,
  "MBTN_LEFT script-binding " .. me .. "/arm-click\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
  "MBTN_RIGHT script-binding " .. me .. "/arm-cancel\n" ..
  "ESC script-binding " .. me .. "/arm-cancel\n" ..
  "H script-binding " .. me .. "/arm-cancel\n" ..
  "h script-binding " .. me .. "/arm-cancel\n" ..
  "ENTER script-binding " .. me .. "/arm-enter\n" ..
  "KP_ENTER script-binding " .. me .. "/arm-enter\n" ..
  "SPACE script-binding " .. me .. "/arm-enter\n", "force")
mp.add_key_binding("H", "hud-mode", arm_toggle)
mp.add_key_binding("h", "hud-mode-h", arm_toggle)
mp.register_script_message("hud-arm-at", function(xy)            -- tests: a press at "x y" on the panel
  local x, y = (xy or ""):match("(%-?%d+)%s+(%-?%d+)")
  if x then arm_press(tonumber(x), tonumber(y)) end
end)
mp.observe_property("osd-dimensions", "native", function()
  if arm.open then local w, h = mp.get_osd_size(); mp.set_mouse_area(0, 0, w or 10000, h or 10000, ARM_SECTION); draw_arm() end
end)
end
mp.register_script_message("hud-mode", function(m)     -- full | light | toggle (IPC / tests)
  set_light(m == "light" or (m ~= "full" and not hud.light), true)
end)
mp.observe_property("osd-dimensions", "native", function()
  if state.visible then render(); set_section(true) else refresh() end
  if tips_open then
    local w, h = mp.get_osd_size()
    mp.set_mouse_area(0, 0, w, h, TIPS_SECTION)
    render_tips()
  end
end)

-- link prompt (empty "omaraptor new" windows) ----------------------------------------------------
-- mpv's console line editor: Ctrl+V and Shift+Insert paste (Omarchy's Super+V sends Ctrl+V);
-- Ctrl+Shift+V is added here. A pasted valid link starts at once, MUTED (this window only; the
-- HUD speaker unmutes). Enter plays a typed link (sound as usual), Esc closes the empty window.
local input_ok, input = pcall(require, "mp.input")
local prompt = { open = false, text = "", reopen = nil, submitted = false, msg = nil }
local hint_ov = mp.create_osd_overlay("ass-events")
hint_ov.z = 10     -- over mpv's console line (we draw the field ourselves), under the HUD (z 20)
local function idle_empty() return idle_empty_now() end
local blink = { on = true, timer = nil }
-- cockpit console (home screen + boot sequence share one layout) ---------------------------------
-- A framed panel: header + status lamp, a 16:9 "screen" (the video plays inside it during boot),
-- a log column, the link bar and a key footer. Pure ASS shapes, drawn only on change (idle: the
-- 2 Hz cursor blink) or by the short boot timer.
function prompt.layout(w, h)
  local g = { w = w, h = h }
  local fs = math.max(11, math.floor(math.min(h * 0.042, w * 0.024)))
  local pad = math.floor(fs * 0.9)
  g.fs, g.pad, g.t = fs, pad, math.max(1, math.floor(math.min(w, h) / 360 + 0.5))
  g.px0, g.py0 = math.floor(w * 0.05), math.floor(h * 0.07)
  g.px1, g.py1 = w - g.px0, h - g.py0
  g.hy = g.py0 + math.floor(fs * 1.5)
  g.footy = g.py1 - math.floor(fs * 0.95)
  g.bh = math.floor(fs * 2.1)
  g.bx0, g.bx1 = g.px0 + pad, g.px1 - pad
  g.by0 = g.footy - math.floor(fs * 0.95) - g.bh
  g.by1 = g.by0 + g.bh
  local top, bot = g.py0 + math.floor(fs * 2.7), g.by0 - math.floor(fs * 0.8)
  local sw = math.min((g.px1 - g.px0 - pad * 3) * 0.62, (bot - top) * 16 / 9)
  local sh = sw * 9 / 16
  g.sx0 = g.px0 + pad; g.sx1 = math.floor(g.sx0 + sw)
  g.sy0 = math.floor(top + (bot - top - sh) / 2); g.sy1 = math.floor(g.sy0 + sh)
  g.lx, g.ly0, g.lx1 = g.sx1 + pad, top, g.px1 - pad
  g.lf = math.max(10, math.floor(fs * 0.62))
  return g
end
-- o: fade (alpha added to all, 0 solid), hole {x0,y0,x1,y1} (left open for the video), fill (idle
-- screen), label/sub (screen text), scan (scanline alpha), lines ({{txt,col,al}..}),
-- bar (segments), barcol, status, lamp (colour or nil), foot (segments)
function prompt.panel(ass, g, o)
  local fa, t, fs = o.fade or 0, g.t, g.fs
  local function A(al) return math.min(255, al + fa) end
  local function box(x0, y0, x1, y1, col, al)
    if x1 <= x0 or y1 <= y0 or A(al) >= 255 then return end
    ass:new_event()
    ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}", col, A(al)))
    ass:draw_start(); ass:rect_cw(x0, y0, x1, y1); ass:draw_stop()
  end
  local function frame(x0, y0, x1, y1, th, col, al)
    box(x0, y0, x1, y0 + th, col, al); box(x0, y1 - th, x1, y1, col, al)
    box(x0, y0 + th, x0 + th, y1 - th, col, al); box(x1 - th, y0 + th, x1, y1 - th, col, al)
  end
  local function brackets(x0, y0, x1, y1, th, len, col, al)
    box(x0, y0, x0 + len, y0 + th, col, al); box(x0, y0, x0 + th, y0 + len, col, al)
    box(x1 - len, y0, x1, y0 + th, col, al); box(x1 - th, y0, x1, y0 + len, col, al)
    box(x0, y1 - th, x0 + len, y1, col, al); box(x0, y1 - len, x0 + th, y1, col, al)
    box(x1 - len, y1 - th, x1, y1, col, al); box(x1 - th, y1 - len, x1, y1, col, al)
  end
  local function segs(list)
    local s = ""
    for _, p in ipairs(list) do
      s = s .. string.format("{\\1c&H%s&\\1a&H%02X&}", p[2] or "FFFFFF", A(p[3] or 0)) .. (p[1]:gsub("[{}\\]", ""))
    end
    return s
  end
  local function txt(x, y, an, f, list, extra)
    if fa >= 250 then return end
    ass:new_event()
    ass:append(string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\q2\\fsp1%s}", an, x, y, MONO, f, extra or "") .. segs(list))
  end
  local w, h, hl = g.w, g.h, o.hole
  if hl then   -- ink all round the open screen
    box(0, 0, w, hl[2], INK, 0); box(0, hl[4], w, h, INK, 0)
    box(0, hl[2], hl[1], hl[4], INK, 0); box(hl[3], hl[2], w, hl[4], INK, 0)
  else box(0, 0, w, h, INK, 0) end
  frame(g.px0, g.py0, g.px1, g.py1, t, ACCENT, 0x90)
  brackets(g.px0, g.py0, g.px1, g.py1, t * 2, math.floor(fs * 1.4), ACCENT, 0x10)
  txt(g.px0 + g.pad, g.hy, 4, math.floor(fs * 0.8), { { "OMARAPTOR", ACCENT, 0 }, { " PLAYER", "FFFFFF", 0x30 } }, "\\fsp3")
  local ls = math.floor(fs * 0.55)
  if o.lamp then box(g.px1 - g.pad - ls, g.hy - ls / 2, g.px1 - g.pad, g.hy + ls / 2, o.lamp, 0) end
  txt(g.px1 - g.pad - ls - math.floor(fs * 0.5), g.hy, 6, g.lf, { { o.status or "", o.statcol or "FFFFFF", 0x10 } }, "\\fsp2")
  box(g.px0 + g.pad, g.hy + math.floor(fs * 0.75), g.px1 - g.pad, g.hy + math.floor(fs * 0.75) + t, ACCENT, 0xB0)
  -- screen
  local sx0, sy0, sx1, sy1 = g.sx0, g.sy0, g.sx1, g.sy1
  frame(sx0 - 2 * t, sy0 - 2 * t, sx1 + 2 * t, sy1 + 2 * t, t, ACCENT, 0x70)
  brackets(sx0 - 3 * t, sy0 - 3 * t, sx1 + 3 * t, sy1 + 3 * t, t * 2, math.floor(fs * 0.8), ACCENT, 0x00)
  if o.fill then box(sx0, sy0, sx1, sy1, "070A06", 0) end
  if o.scan and A(o.scan) < 255 then      -- one shape event for every line
    ass:new_event()
    ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}", o.scancol or "000000", A(o.scan)))
    ass:draw_start()
    for y = sy0, sy1 - t, 3 * t do ass:rect_cw(sx0, y, sx1, y + t) end
    ass:draw_stop()
  end
  if o.label then
    local cx, cy = math.floor((sx0 + sx1) / 2), math.floor((sy0 + sy1) / 2)
    txt(cx, cy - math.floor(fs * 0.3), 2, math.floor(fs * 0.85), o.label, "\\fsp4")
    if o.sub then txt(cx, cy + math.floor(fs * 0.3), 8, g.lf, o.sub, "\\fsp2") end
  end
  -- log column
  local y, step = g.ly0, math.floor(g.lf * 1.6)
  for _, l in ipairs(o.lines or {}) do
    if y > g.by0 - g.lf then break end
    txt(g.lx, y, 7, g.lf, l); y = y + step
  end
  -- link bar
  local bc = o.barcol or ACCENT
  box(g.bx0, g.by0, g.bx1, g.by1, "FFFFFF", 0xF4)
  frame(g.bx0, g.by0, g.bx1, g.by1, t, bc, 0x00)
  box(g.bx0, g.by0, g.bx0 + math.max(3, t * 3), g.by1, bc, 0)
  if o.bar then txt(g.bx0 + math.floor(fs * 0.8), math.floor((g.by0 + g.by1) / 2), 4, math.floor(fs * 0.9), o.bar) end
  if o.foot then txt(math.floor(w / 2), g.footy, 5, g.lf, o.foot, "\\fsp1") end
end
function prompt.wrap(s, n)            -- word wrap for the log column
  local out, cur = {}, ""
  for word in s:gmatch("%S+") do
    if #cur + #word + 1 > n and cur ~= "" then out[#out + 1] = cur; cur = word
    else cur = cur == "" and word or (cur .. " " .. word) end
  end
  if cur ~= "" then out[#out + 1] = cur end
  return out
end
prompt.dump = os.getenv("OMARAPTOR_TEST_DUMP")   -- tests: the drawn home screen as ASS
prompt.foot = { { "SUPER+V", "FFFFFF", 0x30 }, { " PASTE    ", "FFFFFF", 0x98 }, { "ENTER", "FFFFFF", 0x30 },
  { " ENGAGE    ", "FFFFFF", 0x98 }, { "ESC", "FFFFFF", 0x30 }, { " CLOSE", "FFFFFF", 0x98 } }
-- home screen helpers (table fields: the main chunk is at the 200-locals limit)
function prompt.R(ass, x0, y0, x1, y1, col, al)
  if x1 <= x0 or y1 <= y0 or al >= 255 then return end
  ass:new_event()
  ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}", col, al))
  ass:draw_start(); ass:rect_cw(math.floor(x0), math.floor(y0), math.floor(x1), math.floor(y1)); ass:draw_stop()
end
function prompt.T(ass, x, y, an, f, s_, col, al, extra)
  ass:new_event()
  ass:append(string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\q2\\1c&H%s&\\1a&H%02X&%s}%s",
    an, math.floor(x), math.floor(y), MONO, math.floor(f), col, al, extra or "", (s_:gsub("[{}\\]", ""))))
end
-- idle gauge column under the log rows: SIGNAL / BUFFER bars all dark, tiles SAFE / STBY / HOLD
function prompt.idle(ass, g, y, err)
  local R, T = prompt.R, prompt.T
  local x0, x1, u, t = g.lx, g.lx1, g.lf, math.max(1, g.t)
  local lf2 = math.floor(u * 0.85)
  local gx0, gx1 = x0 + math.floor(7 * (lf2 * 0.6 + 2)), x1 - math.floor(6 * (lf2 * 0.6 + 2))
  local gh, n = math.max(6, math.floor(u * 1.2)), 16
  local seg = (gx1 - gx0) / n
  for _, row in ipairs({ { "SIGNAL", err and "LOST" or "--", err and ERR or "FFFFFF" }, { "BUFFER", "--", "FFFFFF" } }) do
    if y + gh > g.sy1 then return end
    ass:new_event()
    ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\1a&HE4&\\p1}"))
    ass:draw_start()
    for i = 0, n - 1 do ass:rect_cw(math.floor(gx0 + i * seg + t), y, math.floor(gx0 + (i + 1) * seg - t), y + gh) end
    ass:draw_stop()
    T(ass, x0, y + gh / 2, 4, lf2, row[1], "FFFFFF", 0x88, "\\fsp2")
    T(ass, x1, y + gh / 2, 6, u, row[2], row[3], row[3] == ERR and 0 or 0xA0, "\\b1\\fsp1")
    y = y + gh + math.floor(u * 1.25)
  end
  local yb, gap = g.sy1 + 3 * g.t, math.max(4, math.floor(u * 0.5))
  local th = math.floor(math.min(u * 5.6, yb - y))
  if th < u * 2.6 then return end
  local ty, tw = yb - th, (x1 - x0 - 2 * gap) / 3
  for i, tl in ipairs({ { "MASTER ARM", "SAFE" }, { "SEEKER", err and "LOST" or "STBY" }, { "RELEASE", "HOLD" } }) do
    local a = x0 + (i - 1) * (tw + gap)
    local e = err and i == 2
    local fc, fa = e and ERR or "FFFFFF", e and 0x20 or 0xC0
    R(ass, a, ty, a + tw, ty + t, fc, fa); R(ass, a, ty + th - t, a + tw, ty + th, fc, fa)
    R(ass, a, ty + t, a + t, ty + th - t, fc, fa); R(ass, a + tw - t, ty + t, a + tw, ty + th - t, fc, fa)
    local lfs = math.floor(math.min(u * 0.82, tw / (#tl[1] * 0.6 + 2.2)))
    T(ass, a + tw / 2, ty + u * 0.55, 8, lfs, tl[1], fc, e and 0 or 0x90, "\\fsp1")
    T(ass, a + tw / 2, ty + th * 0.62, 5, math.floor(math.min(u * 1.5, tw / 4.2)), tl[2], fc, e and 0 or 0xA8, "\\b1\\fsp2")
  end
end
prompt.SEC = "omaraptor-home-paste"     -- the PASTE LINK button's click area
local function draw_hint()
  local w, h = mp.get_osd_size()
  if not w or w <= 0 then return end
  local g = prompt.layout(w, h)
  local ass = assdraw.ass_new()
  local R, T = prompt.R, prompt.T
  local err = prompt.msg ~= nil
  local fc = err and ERR or ACCENT
  local function row(k, v, col, al) return { { string.format("%-10s", k), "FFFFFF", 0x80 }, { v, col or "FFFFFF", al or 0x18 } } end
  local hw = (mp.get_property("hwdec", "no") or "no"):upper()
  local lines = {
    row("SYSTEM", "ONLINE", ACCENT),
    row("CORE", "MPV " .. ((mp.get_property("mpv-version", "") or ""):match("[%d%.]+") or "")),
    row("HUD MODE", hud.light and "CRUISE" or "COMBAT"),
    row("DECODER", hw),
    row("SIGNAL", err and "LOST" or "NONE", err and ERR or "FFFFFF", err and 0x18 or 0x60),
  }
  if err then
    lines[#lines + 1] = {}
    for _, l in ipairs(prompt.wrap(prompt.msg:upper(), math.max(12, math.floor((g.lx1 - g.lx) / (g.lf * 0.6))))) do
      lines[#lines + 1] = { { l, ERR, 0 } }
    end
  end
  local cw = g.fs * 0.9 * 0.6
  local room = math.max(4, math.floor((g.bx1 - g.bx0 - g.fs * 2.6) / cw))
  local s = prompt.text or ""
  if #s > room then s = "…" .. s:sub(-(room - 1)) end
  local cur = { "█", ACCENT, blink.on and 0x00 or 0xFF }
  local bar = (prompt.text or "") == "" and { { "› ", fc, 0 }, cur, { " PASTE SIGNAL LINK", "FFFFFF", 0x90 } }
    or { { "› ", fc, 0 }, { s, "FFFFFF", 0 }, cur }
  prompt.panel(ass, g, { fill = true, scan = 0xE6, scancol = ACCENT,
    lines = lines, bar = bar, barcol = fc, status = err and "NO SIGNAL" or "STANDBY",
    statcol = err and ERR or "FFFFFF", lamp = err and ERR or ((blink.on or prompt.hov) and ACCENT or nil), foot = prompt.foot })
  prompt.idle(ass, g, g.ly0 + (#lines + 0.6) * math.floor(g.lf * 1.6), err)
  -- the screen: idle reticle, NO SIGNAL / AWAITING LINK, one big square PASTE LINK button
  local fs, t = g.fs, g.t
  local sx0, sy0, sx1, sy1 = g.sx0, g.sy0, g.sx1, g.sy1
  local sw, sh = sx1 - sx0, sy1 - sy0
  local cx = math.floor((sx0 + sx1) / 2)
  local th = math.max(2, 2 * t)
  local ix, iy, len = math.floor(sw * 0.07), math.floor(sh * 0.1), math.floor(fs * 1.1)
  local a0, b0, a1, b1 = sx0 + ix, sy0 + iy, sx1 - ix, sy1 - iy
  for _, r in ipairs({ { a0, b0, a0 + len, b0 + t }, { a0, b0, a0 + t, b0 + len }, { a1 - len, b0, a1, b0 + t }, { a1 - t, b0, a1, b0 + len },
      { a0, b1 - t, a0 + len, b1 }, { a0, b1 - len, a0 + t, b1 }, { a1 - len, b1 - t, a1, b1 }, { a1 - t, b1 - len, a1, b1 } }) do
    R(ass, r[1], r[2], r[3], r[4], ACCENT, 0x90)
  end
  local my = math.floor((sy0 + sy1) / 2)
  R(ass, sx0 + math.floor(ix * 0.35), my - t, sx0 + ix - t * 2, my + t, ACCENT, 0xA8)      -- edge ticks
  R(ass, sx1 - ix + t * 2, my - t, sx1 - math.floor(ix * 0.35), my + t, ACCENT, 0xA8)
  local lf, sf = math.floor(fs * 0.85), g.lf
  local bw = math.floor(math.min(sw * 0.62, math.max(fs * 7.5, math.min(sw * 0.46, fs * 11))))
  local bh = math.floor(math.min(sh * 0.42, math.max(fs * 2.6, math.min(sh * 0.36, fs * 4))))
  local stack = lf + sf + math.floor(fs * 1.1) + bh
  local ly = math.floor(my - stack / 2)
  T(ass, cx, ly, 8, lf, "NO SIGNAL", err and ERR or ACCENT, err and 0 or 0x50, "\\fsp4")
  T(ass, cx, ly + lf + math.floor(fs * 0.1), 8, sf, err and "CHECK THE LINK" or "AWAITING LINK", "FFFFFF", 0x80, "\\fsp2")
  local x0, y0 = cx - math.floor(bw / 2), ly + lf + sf + math.floor(fs * 1.1)
  local x1, y1 = x0 + bw, y0 + bh
  prompt.box = { x0, y0, x1, y1 }
  local key = x0 .. " " .. y0 .. " " .. x1 .. " " .. y1
  if key ~= prompt.akey then prompt.akey = key; mp.set_mouse_area(x0, y0, x1, y1, prompt.SEC) end
  local hov = prompt.hov
  R(ass, x0, y0, x1, y1, "070A06", 0x18)
  R(ass, x0, y0, x1, y1, ACCENT, hov and 0x98 or 0xD8)
  R(ass, x0, y0, x1, y0 + th, ACCENT, hov and 0 or 0x30); R(ass, x0, y1 - th, x1, y1, ACCENT, hov and 0 or 0x30)
  R(ass, x0, y0 + th, x0 + th, y1 - th, ACCENT, hov and 0 or 0x30); R(ass, x1 - th, y0 + th, x1, y1 - th, ACCENT, hov and 0 or 0x30)
  local o, bl = th * 3, math.floor(fs * 0.9)
  for _, r in ipairs({ { x0 - o, y0 - o, x0 - o + bl, y0 - o + th }, { x0 - o, y0 - o, x0 - o + th, y0 - o + bl },
      { x1 + o - bl, y0 - o, x1 + o, y0 - o + th }, { x1 + o - th, y0 - o, x1 + o, y0 - o + bl },
      { x0 - o, y1 + o - th, x0 - o + bl, y1 + o }, { x0 - o, y1 + o - bl, x0 - o + th, y1 + o },
      { x1 + o - bl, y1 + o - th, x1 + o, y1 + o }, { x1 + o - th, y1 + o - bl, x1 + o, y1 + o } }) do
    R(ass, r[1], r[2], r[3], r[4], ACCENT, hov and 0x10 or 0x60)
  end
  local f = math.floor(math.min(bh * 0.36, fs * 1.45, bw / 7.5))
  T(ass, cx, math.floor((y0 + y1) / 2 - bh * 0.1), 5, f, "PASTE LINK", hov and "FFFFFF" or "E8FFF4", hov and 0 or 0x10,
    string.format("\\b1\\fsp%d", math.floor(f * 0.25)))
  T(ass, cx, math.floor(y1 - bh * 0.18), 5, math.floor(g.lf * 0.9), "CLICK · SUPER+V", "FFFFFF", 0x60, "\\fsp2")
  hint_ov.res_x, hint_ov.res_y, hint_ov.data = w, h, ass.text
  hint_ov:update()
  if prompt.dump then local f_ = io.open(prompt.dump, "w"); if f_ then f_:write(w, " ", h, "\n", ass.text); f_:close() end end
end
local function blink_stop() if blink.timer then blink.timer:kill(); blink.timer = nil end end
local function blink_start()
  blink_stop(); blink.on = true
  blink.timer = mp.add_periodic_timer(0.5, function() blink.on = not blink.on; draw_hint() end)
end
local open_prompt
local URL_PAT = "^https?://[%w%-%.]+%.[%a][%a]+[/%?#:]?[^%s]*$"
local function play_link(url, muted)
  prompt.submitted = true
  if muted then mp.set_property_bool("mute", true) end
  blink_stop()
  mp.input_disable_section(prompt.SEC)
  input.terminate()
  hint_ov:remove()
  mp.commandv("loadfile", url, "replace")
end
-- Any paste (Super+V -> Ctrl+V, Ctrl+V, Shift+Insert, Ctrl+Shift+V): typing grows the line one
-- character at a time, a paste by many, so a jump that leaves a valid link plays it right away.
local function on_pasted(text)
  local url = (text or ""):gsub("%s", "")
  if url:match(URL_PAT) then play_link(url, true); return true end
  prompt.msg = "Not a web link. Copy a YouTube URL and paste it."; draw_hint()
  return false
end
function prompt.clip()             -- the clipboard as one line (mpv's own clipboard, else wl-paste)
  local clip = mp.get_property("clipboard/text", "")
  if clip == "" then
    local r = utils.subprocess({ args = { "wl-paste", "-n" }, playback_only = false, cancellable = false })
    clip = (r and r.status == 0 and r.stdout) or ""
  end
  return (clip:gsub("[\r\n]", ""))
end
-- PASTE LINK button: the clipboard goes into the field and comes up ARMED (preloads, FIRE plays)
function prompt.button()
  if not prompt.open or prompt.submitted then return end
  local url = prompt.clip():gsub("%s", "")
  if not url:match(URL_PAT) then
    prompt.msg = "Clipboard has no web link. Copy a YouTube URL first."; draw_hint(); return
  end
  prompt.text = url; draw_hint()
  if prompt.arm then prompt.arm() end
  play_link(url, false)
end
mp.add_key_binding(nil, "home-paste", function() prompt.button() end)
mp.input_define_section(prompt.SEC, "MBTN_LEFT script-binding " .. me .. "/home-paste\n" ..
  "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n", "force")
mp.observe_property("mouse-pos", "native", function(_, m)
  if not prompt.open or not prompt.box then return end
  local b = prompt.box
  local hv = (m and m.hover and m.x >= b[1] and m.x < b[3] and m.y >= b[2] and m.y < b[4]) or false
  if hv ~= (prompt.hov or false) then prompt.hov = hv; draw_hint() end
end)
local function prompt_paste()   -- Ctrl+Shift+V: append the clipboard to the line
  if not prompt.open then return end
  local clip = prompt.clip()
  if prompt.text == "" and on_pasted(clip) then return end
  prompt.reopen = prompt.text .. clip
  prompt.reopen_msg = "That isn't a web link. Copy a YouTube URL and paste it."
  input.terminate()
end
local function prompt_keys(on)
  for _, k in ipairs({ "Ctrl+Shift+v", "Ctrl+Shift+V", "Ctrl+V" }) do
    if on then mp.add_forced_key_binding(k, "prompt-paste-" .. k, prompt_paste)
    else mp.remove_key_binding("prompt-paste-" .. k) end
  end
end
open_prompt = function(text, msg)
  if not input_ok then mp.osd_message("This mpv has no link prompt (needs mp.input)", 3); return end
  prompt.open, prompt.submitted, prompt.text, prompt.msg = true, false, text or "", msg
  prompt.akey = nil; draw_hint(); blink_start()
  mp.input_enable_section(prompt.SEC, "allow-hide-cursor")
  prompt_keys(true)
  input.get({
    prompt = "Link: ",
    default_text = prompt.text,
    edited = function(t)
      local before = prompt.text
      prompt.text = t
      blink.on = true; draw_hint()
      if #t - #before > 1 and not prompt.submitted then on_pasted(t) end
    end,
    submit = function(t)
      local url = (t or ""):gsub("%s", "")
      if not url:match(URL_PAT) then
        prompt.reopen = t or ""
        prompt.reopen_msg = "That isn't a web link. Copy a YouTube URL and paste it."
        input.terminate()
        return
      end
      play_link(url, false)
    end,
    closed = function()
      prompt.open = false
      mp.input_disable_section(prompt.SEC)
      prompt_keys(false)
      if prompt.reopen then
        local t, m = prompt.reopen, prompt.reopen_msg
        prompt.reopen, prompt.reopen_msg = nil, nil
        mp.add_timeout(0.01, function() open_prompt(t, m) end)
        return
      end
      blink_stop(); hint_ov:remove()
      if not prompt.submitted and idle_empty() then mp.commandv("quit") end   -- Esc: close
    end,
  })
end
mp.observe_property("osd-dimensions", "native", function() if prompt.open then draw_hint() end end)
if opts.prompt then   -- an empty window: always the clean home screen (never a pre-filled link)
  mp.add_timeout(0.3, function() if idle_empty() then open_prompt("") end end)
end
-- YouTube Mix links (watch?v=ID&list=RD...): the auto-generated mix is endless and resolving it
-- first costs ~14 s; play the one video (autoplay continues with the up-next mix). Real
-- playlists (list=PL..., OLAK...) are untouched. Runs before ytdl_hook (priority 10).
do
  local function unmix(u)
    if not u:match("[?&]list=RD") then return nil end
    if not (u:match("[?&]v=[%w_%-]") or u:match("youtu%.be/[%w_%-]") or u:match("/shorts/") or u:match("/live/")) then return nil end
    local base, q, frag = u:match("^([^?#]*)%??([^#]*)(#?.*)$")
    if not base then return nil end
    local keep = {}
    for kv in q:gmatch("[^&]+") do
      local k = kv:match("^[^=]*")
      if k ~= "list" and k ~= "start_radio" and k ~= "index" and k ~= "pp" then keep[#keep + 1] = kv end
    end
    return base .. (#keep > 0 and ("?" .. table.concat(keep, "&")) or "") .. frag
  end
  prompt.unmix = unmix
  mp.add_hook("on_load", 9, function()
    local u = mp.get_property("stream-open-filename", "")
    local n = unmix(u)
    if n and n ~= u then mp.msg.info("mix link -> single video: " .. n); mp.set_property("stream-open-filename", n) end
  end)
end

-- boot / launcher: the first link of a window. Clipboard start (SUPER+ALT+Y) comes up ARMED: the
-- link resolves and preloads PAUSED inside the console screen (platform, title, length, live
-- buffer) and one big square FIRE button waits - click it, Enter or Space; Esc aborts to the home
-- screen. FIRE (a typed / pasted / launched link fires by itself) runs a ~2.3 s countdown: reticle
-- closing, arming bars, 3-2-1, WEAPONS FREE, then the picture expands to the full window and plays.
-- Not ready by then: STILL ACQUIRING with a live clock. A failed load: NO SIGNAL + RETRY. Timers
-- live only while the console is up (10 Hz armed, 25 Hz in the countdown). Later loads (swap,
-- playlist) get the small card.
;(function()   -- own function scope: the main chunk is at the 200-locals limit
  local B = { ov = mp.create_osd_overlay("ass-events"), clip = os.getenv("OMARAPTOR_CLIPSTART") == "1",
    armed = true, on = false, card = false }
  B.ov.z = 40
  local MR = { "video-margin-ratio-left", "video-margin-ratio-top", "video-margin-ratio-right", "video-margin-ratio-bottom" }
  local CD, GO, REV, CRT = 2.25, 0.3, 0.42, 0.36   -- countdown, WEAPONS FREE hold, expand, CRT switch-on
  B.CDA = 0.9          -- countdown when the link itself was the press (typed / pasted / explicit): stays quick
  local SEC, CORE = "omaraptor-boot-fire", "E8FFF4"
  if B.clip then state.boot = true; mp.set_property_bool("pause", true) end   -- nothing plays before FIRE
  local op = open_prompt
  open_prompt = function(...) B.armed = true; return op(...) end      -- the home screen re-arms it
  prompt.arm = function() B.clip = true end                           -- PASTE LINK: ARMED, FIRE waits
  function B.margins(x0, y0, x1, y1, w, h)
    local v = { x0 / w, y0 / h, (w - x1) / w, (h - y1) / h }
    local key = string.format("%.4f %.4f %.4f %.4f", v[1], v[2], v[3], v[4])
    if key == B.mkey then return end
    B.mkey = key
    for i = 1, 4 do mp.set_property_number(MR[i], math.max(0, math.min(0.49, v[i]))) end
  end
  function B.area(x0, y0, x1, y1)        -- the FIRE button's click rect (0-size: no mouse at all)
    local k = x0 .. " " .. y0 .. " " .. x1 .. " " .. y1
    if k ~= B.akey then B.akey = k; mp.set_mouse_area(x0, y0, x1, y1, SEC) end
  end
  function B.rate(dt)
    if B.timer and B.dt == dt then return end
    if B.timer then B.timer:kill() end
    B.dt, B.timer = dt, mp.add_periodic_timer(dt, function() B.draw() end)
  end
  function B.pub(k)
    if k then B.ts[k] = mp.get_time() - B.t0 end
    mp.set_property_native("user-data/omaraptor-boot", B.ts)      -- tests / timing
  end
  function B.stop()
    state.boot = nil
    if hud.pin then mp.add_timeout(0.05, function() show() end) end   -- pinned: the frame comes up on its own
    if B.timer then B.timer:kill(); B.timer = nil end
    mp.input_disable_section(SEC); B.akey = nil
    if B.on then for i = 1, 4 do mp.set_property_number(MR[i], B.m0[i]) end end
    B.on, B.mkey, B.phase = false, nil, nil
    B.ov:remove()
  end
  function B.finish()
    B.stop()
    if B.idle0 then mp.set_property("idle", B.idle0) end
    show(4)
  end
  function B.launch()
    B.phase, B.tF, B.live = "launch", mp.get_time(), false
    B.pub("fire"); B.rate(0.04); B.draw()
  end
  function B.press()                     -- the one action: FIRE (armed) or RETRY (no signal)
    if B.phase == "armed" then B.flash = mp.get_time(); B.launch()
    elseif B.phase == "fail" then
      B.fail, B.tr, B.loaded, B.flash = nil, nil, nil, mp.get_time()
      mp.set_property_bool("pause", true)
      mp.commandv("loadfile", B.url, "replace")   -- start-file sees B.on: same boot goes on
      B.launch()
    end
  end
  function B.abort()                     -- Esc: back to the home screen, the link still in the field
    if not B.on or B.live then return end
    local url = B.url
    B.clip = false; B.stop()
    mp.set_property("idle", "yes")
    mp.commandv("playlist-clear"); mp.commandv("stop")
    mp.set_property_bool("pause", false)
    mp.add_timeout(0.2, function() if idle_empty() then open_prompt(url or "") end end)
  end
  mp.add_key_binding(nil, "boot-fire", B.press)
  mp.add_key_binding(nil, "boot-abort", B.abort)
  mp.input_define_section(SEC,
    "MBTN_LEFT script-binding " .. me .. "/boot-fire\n" ..
    "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
    "ENTER script-binding " .. me .. "/boot-fire\n" ..
    "KP_ENTER script-binding " .. me .. "/boot-fire\n" ..
    "SPACE script-binding " .. me .. "/boot-fire\n" ..
    "ESC script-binding " .. me .. "/boot-abort\n", "force")
  function B.platform(url)
    local host = ((url or ""):match("^%a+://([^/?#:]+)") or ""):lower():gsub("^www%.", ""):gsub("^m%.", "")
    if host:match("youtube") or host == "youtu.be" then return "YOUTUBE" end
    if host == "x.com" or host:match("twitter%.com$") then return "X" end
    for _, p in ipairs({ "twitch", "tiktok", "vimeo", "kick", "rumble", "dailymotion", "reddit" }) do
      if host:match(p) then return p:upper() end
    end
    return host ~= "" and host:upper() or "LOCAL FILE"
  end
  function B.crt(ass, g, d)   -- old-CRT switch-on: a centre line, then the picture opens vertically
    local x0, y0, x1, y1, t = g.sx0, g.sy0, g.sx1, g.sy1, g.t
    local cx, cy = (x0 + x1) / 2, math.floor((y0 + y1) / 2)
    local function box(a, b, c, e, col, al)
      if c <= a or e <= b then return end
      ass:new_event()
      ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}", col, al))
      ass:draw_start(); ass:rect_cw(a, b, c, e); ass:draw_stop()
    end
    local p1 = math.min(1, d / 0.07)
    local p2 = math.max(0, math.min(1, (d - 0.07) / 0.25))
    local hh = math.max(t, math.floor((y1 - y0) / 2 * (1 - (1 - p2) ^ 3)))   -- eased band half-height
    if p2 <= 0 then box(x0, y0, x1, y1, "000000", 0)     -- still dark: only the line shows
    else box(x0, y0, x1, cy - hh, "000000", 0); box(x0, cy + hh, x1, y1, "000000", 0) end
    local th = math.max(2, t)
    if p2 <= 0 then                                 -- the line: grows out from the centre, white hot
      local hw = (x1 - x0) / 2 * (1 - (1 - p1) ^ 2)
      box(math.floor(cx - hw), cy - th, math.floor(cx + hw), cy + th, "F4FFF8", 0)
      box(math.floor(cx - hw), cy - 4 * th, math.floor(cx + hw), cy + 4 * th, ACCENT, 0xB0)
    else                                            -- it splits: two edges race apart and fade
      local al = math.floor(p2 * 0xD0)
      box(x0, cy - hh - th, x1, cy - hh + th, CORE, al); box(x0, cy + hh - th, x1, cy + hh + th, CORE, al)
    end
    if d >= 0.32 then box(x0, y0, x1, y1, CORE, 0xD8) end   -- one-frame flicker as it settles
  end
  -- gauge cluster (right of the screen): badge + title + chips, SIGNAL and BUFFER bars, and three
  -- annunciator tiles (MASTER ARM / SEEKER / RELEASE). Square shapes only, bars batched into one
  -- event per colour; drawn by the same boot timer, nothing of its own.
  function B.cluster(ass, g, fa, ph, s, el, ready, tgo, T)
    if fa >= 250 then return end
    local x0, x1, y0, yb = g.lx, g.lx1, g.ly0, g.sy1 + 3 * g.t
    local u, t = g.lf, math.max(1, g.t)
    local W = x1 - x0
    local function A(al) return math.min(255, al + fa) end
    local function rects(col, al, list)                        -- many rects, one ASS event
      if #list == 0 or A(al) >= 255 then return end
      ass:new_event()
      ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}", col, A(al)))
      ass:draw_start()
      for _, r in ipairs(list) do ass:rect_cw(math.floor(r[1]), math.floor(r[2]), math.floor(r[3]), math.floor(r[4])) end
      ass:draw_stop()
    end
    local function box(a, b, c, d, col, al) if c > a and d > b then rects(col, al, { { a, b, c, d } }) end end
    local function frame(a, b, c, d, col, al)
      rects(col, al, { { a, b, c, b + t }, { a, d - t, c, d }, { a, b + t, a + t, d - t }, { c - t, b + t, c, d - t } })
    end
    local function txt(x, y, an, f, s_, col, al, extra)
      ass:new_event()
      ass:append(string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\q2\\1c&H%s&\\1a&H%02X&%s}%s",
        an, math.floor(x), math.floor(y), MONO, f, col, A(al), extra or "", (s_:gsub("[{}\\]", ""))))
    end
    local function fit(v, n)                                   -- cut to n chars, never mid UTF-8 sequence
      if #v <= n then return v end
      return (v:sub(1, math.max(1, n - 1)):gsub("[\192-\255][\128-\191]*$", "")) .. "…"
    end
    local blink = math.floor(T * 3) % 2 == 0
    local y = y0
    -- header: platform badge, uploader on the right
    local bf = math.floor(u * 0.92)
    local plat = B.plat or "LINK"
    local bh = math.floor(u * 1.75)
    local bw = math.floor(#plat * (bf * 0.6 + 2) + u * 1.3)
    box(x0, y, x0 + bw, y + bh, ACCENT, 0)
    txt(x0 + bw / 2, y + bh / 2, 5, bf, plat, INK, 0, "\\b1\\fsp2")
    local by = B.loaded and (mp.get_property("metadata/by-key/uploader", "") or "") or ""
    if by ~= "" then
      local sf = math.floor(u * 0.8)
      txt(x1, y + bh / 2, 6, sf, fit(by:upper(), math.floor((W - bw - u) / (sf * 0.6 + 2))), "FFFFFF", 0x60, "\\fsp2")
    end
    y = y + bh + math.floor(u * 0.75)
    -- title: two lines, fixed room so nothing below jumps when it lands
    local tf = math.floor(u * 1.08)
    local lh = math.floor(tf * 1.4)
    local cpl = math.max(8, math.floor(W / (tf * 0.6 + 1)))
    if B.fail then
      txt(x0, y, 7, tf, "NO SIGNAL", ERR, 0, "\\b1\\fsp2")
      local l = prompt.wrap(B.fail:upper(), math.floor(W / (u * 0.8 * 0.6 + 1)))
      if l[1] then txt(x0, y + lh, 7, math.floor(u * 0.8), fit(l[1], cpl + 8), ERR, 0x30, "\\fsp1") end
    elseif B.loaded then
      local tl = prompt.wrap((mp.get_property("media-title", "") or ""):upper(), cpl)
      for i = 1, math.min(2, #tl) do
        txt(x0, y + (i - 1) * lh, 7, tf, (i == 2 and #tl > 2) and fit(tl[2] .. " ", cpl) or tl[i], "FFFFFF", 0, "\\fsp1")
      end
    else
      txt(x0, y, 7, tf, "RESOLVING…", AMBER, blink and 0x10 or 0x70, "\\fsp2")
    end
    y = y + 2 * lh + math.floor(u * 0.5)
    -- chips: LEN / FMT / SRC
    local d = B.loaded and mp.get_property_number("duration") or nil
    local len = (d and d > 0) and (d >= 3600 and string.format("%d:%02d:%02d", math.floor(d / 3600), math.floor(d % 3600 / 60), math.floor(d % 60))
      or string.format("%d:%02d", math.floor(d / 60), math.floor(d % 60))) or nil
    local vh = B.loaded and mp.get_property_number("height") or nil
    local fps = vh and mp.get_property_number("container-fps") or nil
    local fmt = vh and string.format("%dP%s", math.floor(vh), (fps and fps > 31) and tostring(math.floor(fps + 0.5)) or "") or nil
    local chips = { { "LEN", len }, { "FMT", fmt }, { "SRC", B.clip and "CLIP" or "LINK" } }
    local gap = math.max(4, math.floor(u * 0.5))
    local chw, chh, cf = (W - 2 * gap) / 3, math.floor(u * 1.75), math.floor(u * 0.8)
    for i, c in ipairs(chips) do
      local a = x0 + (i - 1) * (chw + gap)
      frame(a, y, a + chw, y + chh, c[2] and ACCENT or "FFFFFF", c[2] and 0x70 or 0xC8)
      txt(a + u * 0.5, y + chh / 2, 4, cf, c[1], "FFFFFF", 0x88, "\\fsp1")
      txt(a + chw - u * 0.5, y + chh / 2, 6, cf, c[2] or "--", c[2] and "FFFFFF" or "FFFFFF", c[2] and 0 or 0xA0, "\\fsp1")
    end
    y = y + chh + math.floor(u * 1.0)
    -- gauges: SIGNAL (acquire, snaps full on LOCK) and BUFFER (live seconds)
    local lf2 = math.floor(u * 0.85)
    local labw = math.floor(7 * (lf2 * 0.6 + 2))
    local valw = math.floor(6 * (lf2 * 0.6 + 2))
    local gx0, gx1 = x0 + labw, x1 - valw
    local gh = math.max(6, math.floor(u * 1.2))
    local function gauge(gy, label, k, col, val, vcol, lead)
      local n = 16
      local seg = (gx1 - gx0) / n
      local on, off = {}, {}
      local lit = math.floor(math.max(0, math.min(1, k)) * n + 0.0001)
      for i = 0, n - 1 do
        local r = { gx0 + i * seg + t, gy, gx0 + (i + 1) * seg - t, gy + gh }
        if i < lit then on[#on + 1] = r else off[#off + 1] = r end
      end
      rects("FFFFFF", 0xE4, off); rects(col, 0, on)
      if lead and lit < n then box(gx0 + lit * seg + t, gy, gx0 + (lit + 1) * seg - t, gy + gh, col, blink and 0x30 or 0x90) end
      txt(x0, gy + gh / 2, 4, lf2, label, "FFFFFF", 0x70, "\\fsp2")
      txt(x1, gy + gh / 2, 6, math.floor(u * 1.0), val, vcol or col, 0, "\\b1\\fsp1")
    end
    if B.fail then gauge(y, "SIGNAL", 0, ERR, "LOST", ERR)
    elseif ready then gauge(y, "SIGNAL", 1, ACCENT, "LOCK")
    else
      local k = B.loaded and 0.82 or 0.72 * (1 - math.exp(-el / 1.3))
      gauge(y, "SIGNAL", k, AMBER, string.format("%.1fS", el), AMBER, true)
    end
    y = y + gh + math.floor(u * 1.25)
    local buf = B.loaded and mp.get_property_number("demuxer-cache-duration") or nil
    if buf then gauge(y, "BUFFER", buf / 30, buf < 3 and AMBER or ACCENT, string.format("%.0fS", buf))
    else gauge(y, "BUFFER", 0, "FFFFFF", "--", "FFFFFF") end
    y = y + gh + math.floor(u * 1.5)
    -- annunciators: dim = off, amber = pending, jade = on (one white blink the tick it lights)
    local th = math.floor(math.min(u * 5.6, yb - y))
    if th < u * 2.6 then return end
    local ty = yb - th
    local tw = (W - 2 * gap) / 3
    if not B.lit or B.lit.t0 ~= B.t0 then B.lit = { t0 = B.t0 } end
    local rel, relbig
    if B.fail or ph ~= "launch" then rel = { "off", "HOLD" }
    elseif tgo and s >= tgo then rel = { "on", "GO" }
    elseif s < B.cd then rel = { "pend", tostring(3 - math.min(2, math.floor(s / (B.cd / 3)))) }; relbig = true
    else rel = { "pend", "WAIT" } end
    local tiles = {
      { "MASTER ARM", (ph == "launch" and not B.fail) and { "on", "ON" } or { "off", "SAFE" } },
      { "SEEKER", B.fail and { "err", "LOST" } or ready and { "on", "LOCK" } or { "pend", "SRCH" } },
      { "RELEASE", rel },
    }
    for i, tl in ipairs(tiles) do
      local a, st = x0 + (i - 1) * (tw + gap), tl[2][1]
      local b, c = a + tw, ty + th
      if st == "on" and not B.lit[i] then B.lit[i] = T elseif st ~= "on" then B.lit[i] = nil end
      local fl = st == "on" and B.lit[i] and T - B.lit[i] < 0.09
      local lc, vc, va
      if st == "on" then
        box(a, ty, b, c, fl and CORE or ACCENT, 0); lc, vc, va = INK, INK, 0
      elseif st == "pend" then
        box(a, ty, b, c, AMBER, 0xD8); frame(a, ty, b, c, AMBER, 0); lc, vc, va = AMBER, AMBER, (relbig and i == 3) and 0 or (blink and 0 or 0x50)
      elseif st == "err" then
        box(a, ty, b, c, ERR, 0xD8); frame(a, ty, b, c, ERR, 0); lc, vc, va = ERR, ERR, 0
      else
        frame(a, ty, b, c, "FFFFFF", 0xC0); lc, vc, va = "FFFFFF", "FFFFFF", 0xA8
      end
      local mx = (a + b) / 2
      local lfs = math.floor(math.min(u * 0.82, tw / (#tl[1] * 0.6 + 2.2)))
      txt(mx, ty + u * 0.55, 8, lfs, tl[1], lc, st == "off" and 0x90 or 0, "\\fsp1")
      local big = (relbig and i == 3) and math.floor(math.min(th * 0.55, u * 2.4)) or math.floor(math.min(u * 1.5, tw / 4.2))
      txt(mx, ty + th * 0.62, 5, big, tl[2][2], vc, va, "\\b1\\fsp2")
    end
  end
  function B.draw()
    B.ov_ass = assdraw.ass_new(); B.tick()
  end
  function B.tick()
    local w, h = mp.get_osd_size()
    if not w or w <= 0 then return end
    local ass, g, T = B.ov_ass, prompt.layout(w, h), mp.get_time()
    local ph, fs, t = B.phase, g.fs, g.t
    local s = B.freeze or (T - (ph == "launch" and B.tF or B.t0))   -- phase clock (freeze: tests)
    local el = ph == "launch" and (T - B.t0) or s                  -- since the link started loading
    local ready = B.tr ~= nil
    local sx0, sy0, sx1, sy1 = g.sx0, g.sy0, g.sx1, g.sy1
    local cx, cy = math.floor((sx0 + sx1) / 2), math.floor((sy0 + sy1) / 2)
    local function box(x0, y0, x1, y1, col, al)
      if x1 <= x0 or y1 <= y0 or al >= 255 then return end
      ass:new_event()
      ass:append(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}", col, al))
      ass:draw_start(); ass:rect_cw(math.floor(x0), math.floor(y0), math.floor(x1), math.floor(y1)); ass:draw_stop()
    end
    local function brk(x0, y0, x1, y1, th, len, col, al)      -- four square corner brackets
      box(x0, y0, x0 + len, y0 + th, col, al); box(x0, y0, x0 + th, y0 + len, col, al)
      box(x1 - len, y0, x1, y0 + th, col, al); box(x1 - th, y0, x1, y0 + len, col, al)
      box(x0, y1 - th, x0 + len, y1, col, al); box(x0, y1 - len, x0 + th, y1, col, al)
      box(x1 - len, y1 - th, x1, y1, col, al); box(x1 - th, y1 - len, x1, y1, col, al)
    end
    local function txt(x, y, an, f, s_, col, al, extra)
      ass:new_event()
      ass:append(string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\q2\\1c&H%s&\\1a&H%02X&%s}%s",
        an, x, y, MONO, f, col, al, extra or "", (s_:gsub("[{}\\]", ""))))
    end
    -- launch timeline: tgo = WEAPONS FREE (countdown done and the picture in), then the expand
    local tgo = (ph == "launch" and ready) and math.max(B.cd, B.tr + CRT - B.tF) or nil
    local e = 0
    if tgo and s >= tgo + GO then
      if not B.live then                          -- release: it plays from here on
        B.live = true; mp.input_disable_section(SEC); B.akey = nil
        mp.set_property_bool("pause", false); B.pub("play")
      end
      e = math.max(0, math.min(1, (s - tgo - GO) / REV))
    end
    local sm = e * e * (3 - 2 * e)
    local function lerp(a, b) return math.floor(a + (b - a) * sm + 0.5) end
    local hole = ready and { lerp(sx0, 0), lerp(sy0, 0), lerp(sx1, w), lerp(sy1, h) } or nil
    if hole then B.margins(hole[1], hole[2], hole[3], hole[4], w, h) else B.margins(sx0, sy0, sx1, sy1, w, h) end
    local blinkon = math.floor(T * 3) % 2 == 0
    -- status lamp, bar, foot
    local status, sc = "ARMED", AMBER
    if B.fail then status, sc = "NO SIGNAL", ERR
    elseif ph == "armed" and ready then status, sc = "TARGET LOCKED", ACCENT
    elseif ph == "launch" then
      if tgo and s >= tgo then status, sc = "WEAPONS FREE", ACCENT
      elseif s >= B.cd then status, sc = "ACQUIRING", AMBER else status, sc = "ENGAGING", AMBER end
    end
    local url = (B.url or ""):gsub("^%a+://", ""):gsub("^www%.", "")
    local room = math.max(8, math.floor((g.bx1 - g.bx0 - fs * 2.6) / (fs * 0.54)))
    if #url > room then url = url:sub(1, room - 1) .. "…" end
    local K, D = "FFFFFF", "FFFFFF"
    local foot = B.fail and { { "ENTER", K, 0x30 }, { " RETRY    ", D, 0x98 }, { "ESC", K, 0x30 }, { " CLOSE", D, 0x98 } }
      or ph == "armed" and { { "ENTER", K, 0x30 }, { " / ", D, 0x98 }, { "SPACE", K, 0x30 }, { " / ", D, 0x98 },
        { "CLICK", K, 0x30 }, { " FIRE    ", D, 0x98 }, { "ESC", K, 0x30 }, { " ABORT", D, 0x98 } }
      or { { "ESC", K, 0x30 }, { " ABORT", D, 0x98 } }
    local scan = 0x90
    if ph == "launch" then scan = math.min(255, 0x90 + math.floor(math.max(0, math.min(1, s / B.cd)) * 0x6F)) end
    prompt.panel(ass, g, { fade = math.floor(255 * sm), hole = hole, fill = not ready, scan = scan,
      lines = {}, bar = { { "› ", ACCENT, 0 }, { url, "FFFFFF", 0x20 } }, barcol = B.fail and ERR or ACCENT,
      status = status, statcol = sc, lamp = (sc ~= AMBER or blinkon) and sc or nil, foot = e > 0 and nil or foot })
    B.cluster(ass, g, math.floor(255 * sm), ph, s, el, ready, tgo, T)
    if ready and T - B.tr < CRT and not B.freeze then B.crt(ass, g, T - B.tr) end
    if e > 0 then                                  -- expanding: only the fading console
      B.area(0, 0, 0, 0)
      B.ov.res_x, B.ov.res_y, B.ov.data = w, h, ass.text
      B.ov:update()
      if e >= 1 and not B.freeze then B.finish() end
      return
    end
    local sw, sh = sx1 - sx0, sy1 - sy0
    if ph == "armed" or ph == "fail" then
      if ready then box(sx0, sy0, sx1, sy1, INK, 0x78) end           -- preview dimmed under the button
      local bw = math.floor(math.max(fs * 6, math.min(sw * 0.46, fs * 10)))
      local bh = math.floor(math.max(fs * 2.4, math.min(sh * 0.36, fs * 3.8)))
      local x0, y0 = cx - math.floor(bw / 2), cy - math.floor(bh / 2) + math.floor(fs * 0.3)
      local x1, y1 = x0 + bw, y0 + bh
      B.area(x0, y0, x1, y1)
      local m = mp.get_property_native("mouse-pos")
      local hov = m and m.hover and m.x >= x0 and m.x < x1 and m.y >= y0 and m.y < y1
      local col = B.fail and AMBER or ACCENT
      local br = 0.5 + 0.5 * math.sin(T * 4)                     -- slow breathing on the outer brackets
      box(x0, y0, x1, y1, "070A06", 0x18)
      box(x0, y0, x1, y1, col, hov and 0x98 or 0xD0)
      local th = math.max(2, 2 * t)
      box(x0, y0, x1, y0 + th, col, 0); box(x0, y1 - th, x1, y1, col, 0)
      box(x0, y0 + th, x0 + th, y1 - th, col, 0); box(x1 - th, y0 + th, x1, y1 - th, col, 0)
      local o = math.floor(th * 2 + br * th * 1.5)
      brk(x0 - o, y0 - o, x1 + o, y1 + o, th, math.floor(fs * 0.9), col, math.floor(0x10 + (1 - br) * 0x60))
      local f = math.floor(math.min(bh * 0.42, fs * 1.7))
      txt(cx, math.floor((y0 + y1) / 2 - bh * 0.08), 5, f, B.fail and "RETRY" or "FIRE", hov and "FFFFFF" or CORE, 0,
        string.format("\\b1\\fsp%d", math.floor(f * 0.3)))
      txt(cx, math.floor(y1 - bh * 0.17), 5, math.floor(g.lf * 0.9), B.fail and "ENTER · CLICK" or "ENTER · SPACE · CLICK", "FFFFFF", 0x50, "\\fsp2")
      local cap, cc = "TARGET LOCKED", ACCENT                     -- caption over the button: what is going on
      if B.fail then cap, cc = "NO SIGNAL", ERR
      elseif not ready then
        local k = math.floor(T * 8) % 4
        cap, cc = "ACQUIRING " .. ("■"):rep(k + 1) .. ("□"):rep(3 - k) .. string.format(" %.1fs", el), AMBER
      end
      txt(cx, y0 - o - math.floor(fs * 0.55), 2, g.lf, cap, cc, 0, "\\fsp3")
    else                                           -- launch: reticle closes, bars arm, 3-2-1
      B.area(0, 0, 0, 0)
      local k = math.min(1, s / B.cd); k = 1 - (1 - k) ^ 2
      if ready then box(sx0, sy0, sx1, sy1, INK, math.min(255, 0x78 + math.floor(k * 0x87))) end
      local ix, iy = sw * 0.16, sh * 0.2                           -- target box half-size
      local ox, oy = sw / 2 - fs * 0.6, sh / 2 - fs * 0.6
      local hx, hy = ox + (ix - ox) * k, oy + (iy - oy) * k
      local lock = s >= B.cd
      if lock then hx = math.max(hx, sw * 0.38) end                 -- open wide around the final word
      local th = math.max(2, 2 * t)
      local rc = (tgo and s >= tgo) and CORE or (lock and AMBER or ACCENT)
      brk(cx - hx, cy - hy, cx + hx, cy + hy, th, math.floor(fs * (1.3 - 0.5 * k)), rc, 0)
      if not lock then                                             -- centre cross with a gap (countdown only)
        local gap, arm = math.floor(fs * 0.5), math.floor(fs * 0.5)
        box(cx - gap - arm, cy - t, cx - gap, cy + t, rc, 0x30); box(cx + gap, cy - t, cx + gap + arm, cy + t, rc, 0x30)
        box(cx - t, cy - gap - arm, cx + t, cy - gap, rc, 0x30); box(cx - t, cy + gap, cx + t, cy + gap + arm, rc, 0x30)
      end
      local n, bw = 12, math.floor(sw * 0.5)                      -- arming bars along the screen foot
      local seg = math.floor(bw / n)
      local bx, by1 = cx - math.floor(seg * n / 2), sy1 - math.floor(fs * 0.7)
      local by0 = by1 - math.max(4, math.floor(fs * 0.4))
      local lit = math.floor(math.min(1, s / B.cd) * n + 0.0001)
      local scanpos = (lock and not tgo) and math.floor(s * 10) % (2 * n - 2) or nil
      if scanpos and scanpos >= n then scanpos = 2 * n - 2 - scanpos end
      for i = 0, n - 1 do
        local on = scanpos and math.abs(i - scanpos) <= 1 or (not scanpos and i < lit)
        box(bx + i * seg + t, by0, bx + (i + 1) * seg - t, by1, on and (scanpos and AMBER or ACCENT) or "FFFFFF", on and 0 or 0xC8)
      end
      local big = math.floor(math.min(sh * 0.3, fs * 3.4))
      if tgo and s >= tgo then
        txt(cx, cy, 5, math.floor(big * 0.5), "WEAPONS FREE", CORE, 0, string.format("\\b1\\fsp%d", math.floor(big * 0.08)))
      elseif lock then
        txt(cx, cy - math.floor(fs * 0.2), 2, math.floor(big * 0.36), "STILL ACQUIRING", AMBER, blinkon and 0 or 0x40, "\\b1\\fsp4")
        txt(cx, cy + math.floor(fs * 0.3), 8, g.lf, string.format("%.1fs", el), "FFFFFF", 0x30, "\\fsp2")
      else
        local step = B.cd / 3
        local i = math.min(2, math.floor(s / step))
        local u = (s - i * step) / step
        local sc_ = math.floor(100 + 45 * (1 - u) ^ 3)
        txt(cx, cy, 5, big, tostring(3 - i), CORE, math.floor(math.max(0, u - 0.75) / 0.25 * 0xC0),
          string.format("\\b1\\fscx%d\\fscy%d", sc_, sc_))
      end
    end
    if B.flash and T - B.flash < 0.12 then box(sx0, sy0, sx1, sy1, CORE, 0x90) end   -- the press: one white blink
    B.ov.res_x, B.ov.res_y, B.ov.data = w, h, ass.text
    B.ov:update()
  end
  function B.draw_card()   -- later loads (swap, playlist): the small loading card
    local w, h = mp.get_osd_size()
    if not w or w <= 0 then w, h = 960, 540 end
    local fs = math.max(13, math.floor(h * 0.04))
    local host = (mp.get_property("path", "") or ""):match("^%a+://([^/?#]+)") or ""
    local function line(y, size, col, al, t)
      return string.format("{\\an5\\pos(%d,%d)\\fn%s\\fs%d\\fsp2\\bord0\\shad0\\1c&H%s&\\1a&H%s&}%s\n",
        math.floor(w / 2), y, MONO, size, col, al, t)
    end
    local cy = math.floor(h / 2)
    B.ov.res_x, B.ov.res_y = w, h
    B.ov.data = line(cy - fs, fs, ACCENT, "00", "ACQUIRING SIGNAL") ..
      line(cy + math.floor(fs * 0.4), math.floor(fs * 0.7), "FFFFFF", "70", host:upper())
    B.ov:update()
  end
  mp.register_event("start-file", function()
    if B.on then return end                    -- redirect / playlist expansion / RETRY: same boot goes on
    if not B.armed then B.card = true; B.draw_card(); return end
    B.armed, B.on, B.tr, B.fail, B.loaded, B.mkey, B.live, B.flash = false, true, nil, nil, nil, nil, false, nil
    B.t0, B.ts = mp.get_time(), {}
    B.url = mp.get_property("path", "") or ""
    B.plat = B.platform(B.url)
    state.boot = true                          -- the HUD waits: it pops in when the picture is full size
    mp.set_property_bool("pause", true)        -- preload paused: yt-dlp, demux and the first frame, silent
    B.m0 = {}
    for i = 1, 4 do B.m0[i] = mp.get_property_number(MR[i], 0) end
    B.idle0 = mp.get_property("idle")
    if B.idle0 ~= "yes" then mp.set_property("idle", "yes") end   -- a failed link shows NO SIGNAL, not a vanished window
    mp.input_enable_section(SEC, "allow-hide-cursor")
    B.cd = B.clip and CD or B.CDA
    if B.clip then B.phase = "armed"; B.rate(0.1); B.draw() else B.launch() end
  end)
  mp.register_event("file-loaded", function() if B.on then B.loaded = true end end)
  mp.register_event("playback-restart", function()
    if B.card then B.card = false; B.ov:remove() end
    if B.on and not B.tr and not B.fail then
      B.tr = mp.get_time()
      B.tf = B.tr - B.t0
      B.ts.tf = B.tf; B.pub()
    end
  end)
  mp.register_event("end-file", function(ev)
    if B.card then B.card = false; B.ov:remove() end
    if not B.on or ev.reason == "redirect" then return end
    if ev.reason == "error" and not B.fail then
      B.fail = (ev.file_error or "load failed"):upper()
      B.phase, B.tr, B.live = "fail", nil, false
      B.pub("fail"); B.rate(0.1); B.draw()
    elseif not B.fail then B.stop() end
  end)
  mp.register_script_message("omaraptor-boot-freeze", function(v) B.freeze = tonumber(v); if B.on then B.draw() end end)
end)()

-- first-launch key card: shown once (state file), after the first picture of the first video.
-- Any player key, a click, or 6 s dismisses it; "?" opens the full panel. No timers once shown.
do
  -- one local only (the main chunk is close to Lua's 200-local limit)
  local card = { open = false, checked = false, to = nil, tries = 0, SECTION = "omaraptor-hud-card",
    ov = mp.create_osd_overlay("ass-events") }
  card.ov.z = 35
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or "") .. "/.local/state" end
  card.DIR = base .. "/omaraptor"
  card.FILE = card.DIR .. "/first-launch-seen"
  card.ROWS = {
    { "SPACE / K", "play · pause" }, { "← →  /  J L", "5 s  /  10 s" }, { "↑ ↓   M", "volume · mute" },
    { "0 – 9", "jump to 0–90 %" }, { "<  >", "speed" }, { "N", "next video" },
    { "F   ESC", "fullscreen · exit" }, { "H", "arm panel" }, { "?", "all keys" },
  }
  function card.draw()
    local w, h = mp.get_osd_size()
    if not w or w <= 0 or h <= 0 then return end
    local fs = math.max(9, math.floor(h * 0.0185))
    local cw = math.floor(fs * 30)
    if cw > w * 0.92 then fs = math.max(8, math.floor(w * 0.92 / 30)); cw = math.floor(fs * 30) end
    local rh, head_h, foot_h = math.floor(fs * 1.6), math.floor(fs * 2.6), math.floor(fs * 2.2)
    local chh = head_h + #card.ROWS * rh + foot_h + math.floor(fs * 0.6)
    local x, y = math.floor((w - cw) / 2), math.floor((h - chh) / 2)
    local bt, m = math.max(2, math.floor(fs * 0.12 + 0.5)), math.max(3, math.floor(fs * 0.35))
    local function rect(x0, y0, x1, y1) return string.format("m %d %d l %d %d l %d %d l %d %d ", x0, y0, x1, y0, x1, y1, x0, y1) end
    local out = {}
    local function shp(col, al, d) out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}", col, al, d) end
    local function txt(tx, ty, an, f, col, al, body, extra)
      out[#out + 1] = string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\q2\\fsp0\\1c&H%s&\\1a&H%02X&%s}%s",
        an, tx, ty, MONO, f, col, al, extra or "", body)
    end
    shp(INK, 0x18, rect(x, y, x + cw, y + chh))
    shp(ACCENT, 0x00, rect(x, y, x + cw, y + bt) .. rect(x, y + chh - bt, x + cw, y + chh) ..
      rect(x, y + bt, x + bt, y + chh - bt) .. rect(x + cw - bt, y + bt, x + cw, y + chh - bt) ..
      rect(x - m, y - m, x + m, y + m) .. rect(x + cw - m, y - m, x + cw + m, y + m) ..
      rect(x - m, y + chh - m, x + m, y + chh + m) .. rect(x + cw - m, y + chh - m, x + cw + m, y + chh + m))
    local pad = math.floor(fs * 1.1)
    txt(x + pad, y + math.floor(head_h * 0.5), 4, math.floor(fs * 1.05), ACCENT, 0, "KEYS", "\\b1\\fsp1")
    txt(x + cw - pad, y + math.floor(head_h * 0.5), 6, math.floor(fs * 0.75), AMBER, 0, "FIRST LAUNCH", "\\fsp1")
    shp(ACCENT, 0x90, rect(x + pad, y + head_h - 1, x + cw - pad, y + head_h))
    local kx, dx = x + math.floor(cw * 0.39), x + math.floor(cw * 0.43)
    for i, r in ipairs(card.ROWS) do
      local ry = y + head_h + math.floor(fs * 0.3) + math.floor((i - 0.5) * rh)
      txt(kx, ry, 6, fs, ACCENT, 0, r[1], "\\b1")
      txt(dx, ry, 4, fs, "F0F0F0", 0x08, r[2])
    end
    txt(x + math.floor(cw / 2), y + chh - math.floor(foot_h * 0.55), 5, math.floor(fs * 0.72), "B4B4B4", 0x20,
      "any key · click · 6 s to dismiss   ·   ? brings it back", "\\fsp1")
    card.ov.res_x, card.ov.res_y, card.ov.data = w, h, table.concat(out, "\n")
    card.ov:update()
  end
  function card.off()
    if card.to then card.to:kill(); card.to = nil end
    if not card.open then return end
    card.open = false
    mp.input_disable_section(card.SECTION)
    card.ov:remove()
    mp.set_property_native("user-data/omaraptor-hud-card", { open = false, file = card.FILE })
  end
  function card.raise()
    if not card.open then return end
    local w, h = mp.get_osd_size()
    mp.set_mouse_area(0, 0, w or 10000, h or 10000, card.SECTION)
    mp.input_disable_section(card.SECTION); mp.input_enable_section(card.SECTION)
  end
  function card.open_()
    card.to = nil
    if card.open or tips_open or prompt.open then return end
    if state.boot then                            -- boot sequence still on screen: try again shortly
      card.tries = card.tries + 1
      if card.tries < 40 then card.to = mp.add_timeout(0.3, card.open_) end
      return
    end
    mp.command_native({ name = "subprocess", args = { "mkdir", "-p", card.DIR }, playback_only = false,
      capture_stdout = true, capture_stderr = true })
    local f = io.open(card.FILE, "w")
    if f then f:write(os.date("%Y-%m-%dT%H:%M:%S") .. "\n"); f:close() end
    card.open = true
    card.draw(); card.raise()
    card.to = mp.add_timeout(6, card.off)
    mp.set_property_native("user-data/omaraptor-hud-card", { open = true, file = card.FILE })
  end
  hud.card_off, hud.card_raise = card.off, card.raise
  mp.add_key_binding(nil, "card-close", card.off)
  mp.add_key_binding(nil, "card-esc", function() card.off(); mp.set_property_bool("fullscreen", false) end)
  mp.add_key_binding(nil, "card-click", function(e) if e.event == "down" or e.event == "press" then card.off() end end, { complex = true })
  mp.input_define_section(card.SECTION,
    "MBTN_LEFT script-binding " .. me .. "/card-click\n" ..
    "MBTN_LEFT_DBL script-binding " .. me .. "/nop\n" ..
    "ESC script-binding " .. me .. "/card-esc\n", "force")
  mp.register_event("playback-restart", function()
    if card.checked then return end
    card.checked = true
    local f = io.open(card.FILE, "r")
    if f then f:close(); return end               -- seen before: never again
    card.to = mp.add_timeout(0.3, card.open_)
  end)
  mp.observe_property("osd-dimensions", "native", function() if card.open then card.draw(); card.raise() end end)
end

mp.register_script_message("omaraptor-hud", function(cmd, arg)
  if hud.card_off and (cmd == "flash" or cmd == "key" or cmd == "resize" or cmd == "tips" or cmd == "card-off") then
    hud.card_off()
  end
  if cmd == "card-off" then return end
  if cmd == "key" then              -- input.conf keys that drive a bar tile: same action + press flash
    if arg == "spd+" or arg == "spd-" then spd_step(arg == "spd+" and 1 or -1); press_flash("spd")
    elseif actions[arg] then
      local msg = actions[arg]()
      press_flash(arg)
      if msg then set_status(msg) end
      show(1.2)
    end
    return
  end
  if cmd == "flash" then
    if arg and arg ~= "" then mp.osd_message(arg, 0.8) end
    state.hot = nil
    show(1.2)
  elseif cmd == "title" then        -- new video: show its title with the bar for a moment
    -- the neon ticker carries the title now; plain OSD text only when it is off
    if arg and arg ~= "" and (opts.title == "off" or not HUD()) then mp.osd_message(arg, 3) end
    state.hot = nil
    show(3)
  elseif cmd == "resize" then
    resize(arg and arg ~= "" and arg or "larger")
  elseif cmd == "position" then
    mp.osd_message("Controls: bottom bar", 0.8)
    show(1.2)
  elseif cmd == "tips" then
    if arg == "open" then if not tips_open then open_tips() end
    elseif arg == "close" then close_tips()
    else toggle_tips() end
  elseif cmd == "hide" then
    hide(true)
  elseif cmd == "vol-pin" then      -- preview: keep the volume graphic up (for screenshots)
    volfx.pin = arg == "yes"; vol_pop()   -- unpin: normal hold + fade
  elseif cmd == "title-pos" then    -- neon title placement: top | row | off
    opts.title = arg; render()
  elseif cmd == "title-demo" then   -- preview: override the title text ("" = media-title)
    marquee.demo = (arg ~= "" and arg) or nil; marquee.t0 = mp.get_time(); render()
  elseif cmd == "style" then        -- live switch between the three looks (design preview)
    if STYLES[arg] then style = arg; render(); remfx.sync() end
  elseif cmd == "hover" then        -- preview hooks: hover / press a button by name
    state.hot = (arg ~= "" and arg) or nil; state.preview_x = nil; show(30); render()
  elseif cmd == "scope-at" then     -- preview: freeze the scope animation at t seconds ("" = live)
    fpm.freeze = tonumber(arg); if fpm.freeze then fpm.paused = mp.get_property_bool("pause") end; show(30); render()
  elseif cmd == "hover-at" then     -- preview: pointer at "x y" (OSD px), hot = what is under it
    local x, y = arg:match("^(%-?[%d.]+)%s+(%-?[%d.]+)$")
    if x then state.mx, state.my, state.mhover = tonumber(x), tonumber(y), true; state.hot = hit(state.mx, state.my) end
    show(30); render()
  elseif cmd == "click-at" then     -- preview: a click at "x y" (same path as a real press)
    local x, y = arg:match("^(%-?[%d.]+)%s+(%-?[%d.]+)$")
    if x then
      local m = { x = tonumber(x), y = tonumber(y), hover = true }
      local real = mp.get_property_native
      mp.get_property_native = function(p, d) if p == "mouse-pos" then return m end return real(p, d) end
      ;(tips_open and tips_click or click)({ event = "press" }); mp.get_property_native = real
    end
  elseif cmd == "geom" then         -- preview: log a button's rect (and its cells) for tests
    local r = state.buttons[arg]
    if r then mp.msg.warn(string.format("geom %s %d %d %d %d cells=%s", arg, r.x, r.y, r.w, r.h,
      r.cells and string.format("%d,%d,%d,%d", r.cells.x0, r.cells.cw, r.cells.gp, r.cells.y0) or "-")) end
  elseif cmd == "hover-seek" then
    state.hot = "seek"; state.preview_x = tonumber(arg); show(30); render()
  elseif cmd == "press" then
    press_flash(arg, true); show(30); render()
  elseif cmd == "release" then
    press_fx.name = nil; state.hot = nil; state.preview_x = nil; render()
  elseif cmd == "status" then
    if arg == "" then status.until_t = 0 else set_status(arg, 30) end; render()
  elseif cmd == "prompt" then
    if not prompt.open then open_prompt("") end
  elseif cmd == "prompt-paste" then   -- same path as a real paste (used for testing)
    if prompt.open and not on_pasted(arg) then
      prompt.reopen = arg or ""; prompt.reopen_msg = "That isn't a web link. Copy a YouTube URL and paste it."
      input.terminate()
    end
  end
end)

publish()
