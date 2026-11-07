-- Render the HUD to ASS for stills. Not part of CI (needs ffmpeg and the fonts).
-- usage: lua tests/render-shots.lua <omaraptor-hud.lua> <outdir>
local script, outdir = arg[1], arg[2]
local scenes = {
  { "full-off", 1920, 1080, true, "off", true },
  { "full-dim", 1920, 1080, true, "dim", false },
  { "full-dimmer", 1920, 1080, true, "dimmer", false },
  { "small-off", 614, 345, false, "off", true },
  { "small-dim", 614, 345, false, "dim", false },
  { "small-dimmer", 614, 345, false, "dimmer", false },
}
local W, H = 1280, 720
local now = 1000
local props = {
  duration = 180, ["time-pos"] = 72, pause = true, fullscreen = false,
  mute = false, volume = 80, speed = 1, path = "/nonexistent/clip.mkv",
  ["media-title"] = "Roman night run", ["container-fps"] = 25,
  ["demuxer-via-network"] = false, ["idle-active"] = false, ["playlist-count"] = 1,
  ["estimated-frame-number"] = 900, ["loop-file"] = "no",
}
local timers, observers, overlays, handlers = {}, {}, {}, {}
local function T(cb, iv, periodic)
  local t = { cb = cb, timeout = iv, on = true, periodic = periodic }
  function t:kill() self.on = false end
  function t:resume() self.on = true end
  function t:stop() self.on = false end
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
  set_property_number = function(k, v) props[k] = v end,
  set_property_bool = function() end,
  set_property_native = function() end,
  get_osd_size = function() return W, H end,
  create_osd_overlay = function()
    local o = { data = "" }
    function o:update() self.n = (self.n or 0) + 1; overlays[self] = self.data end
    function o:remove() overlays[self] = nil; self.data = "" end
    overlays[#overlays + 1] = o
    return o
  end,
  add_periodic_timer = function(iv, cb) return T(cb, iv, true) end,
  add_timeout = function(iv, cb) return T(cb, iv, false) end,
  observe_property = function(k, _, cb) observers[#observers + 1] = { k, cb } end,
  register_event = function() end,
  register_script_message = function(name, cb) handlers[name] = cb end,
  get_script_name = function() return "omaraptor-hud" end,
  command_native = function() return {} end,
  command_native_async = function() end,
  commandv = function() end,
  osd_message = function() end,
}, { __index = function() return function() end end })
package.preload["mp.options"] = function() return { read_options = function() end } end
package.preload["mp.utils"] = function()
  return { format_json = function() return "{}" end, subprocess = function() return { status = 0, stdout = "" } end,
    parse_json = function() return nil end, join_path = function(a, b) return a .. "/" .. b end,
    getcwd = function() return "/tmp" end, file_info = function() return nil end,
    split_path = function(p) return "/tmp/", p end, get_env_list = function() return {} end }
end
package.preload["mp.msg"] = function() return setmetatable({}, { __index = function() return function() end end }) end
package.preload["mp.input"] = function() error("no input") end
package.preload["mp.assdraw"] = function() error("not used") end
dofile(script)
for _, o in ipairs(observers) do if o[1] == "pause" then o[2]("pause", true) end end
for _ = 1, 40 do
  now = now + 0.05
  for _, t in ipairs(timers) do
    if t.on and t.periodic and t.timeout and t.timeout <= 0.05 then t.cb() end
  end
end
local function wrap(w, h, body, path)
  local f = io.open(path, "w")
  f:write(string.format("[Script Info]\nScriptType: v4.00+\nPlayResX: %d\nPlayResY: %d\nWrapStyle: 2\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,JetBrains Mono,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n", w, h))
  for line in (body or ""):gmatch("[^\n]+") do
    if line:match("%S") then
      f:write("Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,", line, "\n")
    end
  end
  f:close()
end
local man = io.open(outdir .. "/manifest.txt", "w")
for _, s in ipairs(scenes) do
  local name, w, h, fs, night, pin = s[1], s[2], s[3], s[4], s[5], s[6]
  W, H = w, h
  props.fullscreen = fs
  handlers.pin(pin and "on" or "off")
  handlers["omaraptor-hud"]("title-demo", "Roman night run")
  handlers["omaraptor-hud"]("night", night)
  local hud = overlays[1] and overlays[1].data or ""
  local veil = overlays[overlays[2]] or ""
  wrap(w, h, hud, outdir .. "/" .. name .. ".hud.ass")
  wrap(w, h, veil, outdir .. "/" .. name .. ".veil.ass")
  man:write(string.format("%s %d %d %s %s\n", name, w, h, night, pin and "pin" or "free"))
  io.write(string.format("ass  %s %dx%d night=%s pin=%s hud=%d veil=%d\n", name, w, h, night, tostring(pin), #hud, #veil))
end
man:close()
