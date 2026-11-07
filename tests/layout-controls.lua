-- Geometry of the control cluster: nothing overlaps or leaves the window, PIN stays
-- readable at the corner size and at fullscreen, and night persists in script-opts.
-- usage: lua tests/layout-controls.lua <omaraptor-hud.lua>
local script = arg[1]
local root = os.getenv("XDG_CONFIG_HOME")
if not root or root == "" then io.write("FAIL XDG_CONFIG_HOME\n"); os.exit(1) end
local conf = root .. "/omaraptor/script-opts/omaraptor-hud.conf"
os.execute(string.format("mkdir -p %q", root .. "/omaraptor/script-opts"))
local cf = io.open(conf, "w")
cf:write("timeout=7\npin=no\ncustom=kept\nnight=off\n")
cf:close()
local scenes = {
  { 1920, 1080, true }, { 1920, 1080, false },
  { 614, 345, false }, { 2560, 1440, true }, { 819, 461, false },
  { 1366, 768, true }, { 437, 246, false }, { 360, 202, false },
}
local W, H, FS = 1280, 720, false
local now = 1000
local props = {
  duration = 180, ["time-pos"] = 40, pause = true, fullscreen = false,
  mute = false, volume = 80, speed = 1, path = "/nonexistent/clip.mkv",
  ["media-title"] = "Night run", ["container-fps"] = 25,
  ["demuxer-via-network"] = false, ["idle-active"] = false, ["playlist-count"] = 1,
  ["estimated-frame-number"] = 100, ["osd-dimensions"] = { w = 1280, h = 720 },
}
local timers, observers, overlays, events, msgs = {}, {}, {}, {}, {}
local function T(cb, iv, periodic)
  local t = { cb = cb, timeout = iv, on = true, periodic = periodic }
  function t:kill() self.on = false end
  function t:resume() self.on = true end
  function t:stop() self.on = false end
  function t:is_enabled() return self.on end
  timers[#timers + 1] = t
  return t
end
mp = setmetatable({
  get_time = function() return now end,
  get_property = function(k, d) local v = props[k]; if v == nil then return d end; return tostring(v) end,
  get_property_number = function(k, d) local v = props[k]; if type(v) == "number" then return v end; return d end,
  get_property_bool = function(k, d) local v = props[k]; if type(v) == "boolean" then return v end; return d end,
  get_property_native = function(k, d) local v = props[k]; if v == nil then return d end; return v end,
  set_property = function() end,
  set_property_number = function() end,
  set_property_bool = function() end,
  set_property_native = function() end,
  get_osd_size = function() return W, H end,
  create_osd_overlay = function()
    local o = { data = "", n = 0 }
    function o:update() self.n = self.n + 1; overlays[self] = self.data end
    function o:remove() overlays[self] = nil end
    overlays[#overlays + 1] = o
    return o
  end,
  add_periodic_timer = function(iv, cb) return T(cb, iv, true) end,
  add_timeout = function(iv, cb) return T(cb, iv, false) end,
  observe_property = function(k, _, cb) observers[#observers + 1] = { k, cb } end,
  register_event = function(k, cb) events[#events + 1] = { k, cb } end,
  register_script_message = function(name, cb) msgs[name] = cb end,
  get_script_name = function() return "omaraptor-hud" end,
  command_native = function() return {} end,
  command_native_async = function() end,
  commandv = function() end,
  osd_message = function() end,
  msg = { warn = function(s) msgs[#msgs + 1] = s end },
}, { __index = function() return function() end end })
package.preload["mp.options"] = function() return { read_options = function() end } end
package.preload["mp.utils"] = function()
  return { format_json = function() return "{}" end, subprocess = function() return { status = 0, stdout = "" } end,
    parse_json = function() return nil end, join_path = function(a, b) return a .. "/" .. b end,
    getcwd = function() return "/tmp" end, file_info = function() return nil end,
    split_path = function(p) return "/tmp/", p end, get_env_list = function() return {} end }
end
package.preload["mp.msg"] = function()
  return setmetatable({ warn = function(s) msgs[#msgs + 1] = s end }, { __index = function() return function() end end })
end
package.preload["mp.input"] = function() error("no input") end
package.preload["mp.assdraw"] = function() error("not used") end

local function fail(s) io.write("FAIL ", s, "\n"); os.exit(1) end
local function settle()
  for _, o in ipairs(observers) do if o[1] == "pause" then o[2]("pause", true) end end
  for _ = 1, 40 do
    now = now + 0.05
    for _, t in ipairs(timers) do
      if t.on and t.periodic and t.timeout and t.timeout <= 0.05 then t.cb() end
    end
  end
end

dofile(script)
settle()

local function box_of(name)
  for i = #msgs, 1, -1 do
    local x, y, w, h = msgs[i]:match("^geom " .. name .. " (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)")
    if x then return { name = name, x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) } end
  end
end

local function pin_fs(data)
  local best = 0
  for ev in (data or ""):gmatch("[^\n]+") do
    if ev:find("}PIN", 1, true) or ev:find("}PIN ", 1, true) then
      local fs = tonumber(ev:match("\\fs(%d+)"))
      if fs and fs > best then best = fs end
    end
  end
  return best
end

local names = { "pin", "hud", "smaller", "larger", "fs", "night", "help", "new", "play", "back", "fwd", "vol", "spd", "loop", "link", "seek", "htape", "vtape", "ttape", "vgauge" }
local skip = { ["vol+vgauge"] = true, ["vgauge+vol"] = true }

local function check(w, h, fs)
  W, H, FS = w, h, fs
  props.fullscreen = fs
  local hudmsg = msgs["omaraptor-hud"]
  if not hudmsg then fail("no hud message handler") end
  hudmsg("hover", "")
  for i = #msgs, 1, -1 do msgs[i] = nil end
  local boxes = {}
  for _, name in ipairs(names) do
    hudmsg("geom", name)
    local b = box_of(name)
    if b then boxes[#boxes + 1] = b end
  end
  local by = {}
  for _, b in ipairs(boxes) do by[b.name] = b end
  for _, b in ipairs(boxes) do
    if b.w <= 0 or b.h <= 0 then fail(string.format("%dx%d fs=%s %s non-positive", w, h, tostring(fs), b.name)) end
    if b.x < -1 or b.y < -1 or b.x + b.w > w + 1 or b.y + b.h > h + 1 then
      fail(string.format("%dx%d fs=%s %s outside %d %d %d %d", w, h, tostring(fs), b.name, b.x, b.y, b.w, b.h))
    end
  end
  for i = 1, #boxes do
    for j = i + 1, #boxes do
      local a, b = boxes[i], boxes[j]
      if not skip[a.name .. "+" .. b.name] then
        local ow = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
        local oh = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
        if ow > 1 and oh > 1 then
          fail(string.format("%dx%d fs=%s overlap %s %s", w, h, tostring(fs), a.name, b.name))
        end
      end
    end
  end
  if by.seek and by.pin and by.pin.y < by.seek.y + by.seek.h - 1 then
    fail(string.format("%dx%d pin overlaps seek", w, h))
  end
  if w >= 560 and not by.night then fail(string.format("%dx%d missing night", w, h)) end
  if by.night and by.help then
    local a, b = by.night, by.help
    local ow = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    if ow > 0 and math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y) > 0 then
      fail("night overlaps help")
    end
  end
  local need_word = (w == 614 and h == 345) or (w == 1920 and h == 1080)
  if need_word then
    if not by.pin or by.pin.h < 28 then
      fail(string.format("%dx%d pin too small %s", w, h, by.pin and tostring(by.pin.h) or "missing"))
    end
    local pfs = pin_fs(overlays[1] and overlays[1].data or "")
    if pfs < 13 then fail(string.format("%dx%d PIN font %d", w, h, pfs)) end
  end
  if w == 360 then
    local pfs = pin_fs(overlays[1] and overlays[1].data or "")
    if pfs > 0 and pfs < 13 then fail("small window drew an unreadable PIN") end
  end
  io.write(string.format("ok   %4dx%-4d fs=%d pin=%s night=%s\n", w, h, fs and 1 or 0,
    by.pin and string.format("%dx%d", by.pin.w, by.pin.h) or "-",
    by.night and string.format("%dx%d", by.night.w, by.night.h) or "-"))
end

for _, s in ipairs(scenes) do check(s[1], s[2], s[3]) end

local function read_conf()
  local f = io.open(conf, "r")
  if not f then fail("conf missing") end
  local body = f:read("*a"); f:close(); return body
end
local handler = msgs["omaraptor-hud"]
handler("night")
local body = read_conf()
if not body:find("night=dim\n") and not body:find("night=dim$") then fail("did not save night=dim: " .. body) end
if not body:find("custom=kept") or not body:find("pin=no") then fail("night save clobbered conf") end
handler("night")
body = read_conf()
if not body:find("night=dimmer") then fail("did not save night=dimmer") end
handler("night")
body = read_conf()
if not body:find("night=off") then fail("did not save night=off") end
if body:find("night=dimmer") or body:find("night=dim\n") then fail("old night level left behind") end
io.write("ok   night persisted\n")
