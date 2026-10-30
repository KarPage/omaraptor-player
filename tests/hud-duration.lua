-- Regression test for forged media durations: loads omaraptor-hud.lua under a mock mpv API,
-- renders frames and fails if the OSD grows with the claimed duration.
-- usage: lua tests/hud-duration.lua <script> <duration|inf|nan> <fullscreen 0|1> <frames> [w h pos]
local script, durs, fsarg, frames, W, H, POS = arg[1], arg[2], arg[3] == "1", tonumber(arg[4] or 1), tonumber(arg[5] or 1280), tonumber(arg[6] or 720), tonumber(arg[7])
local dur = (durs == "inf" and math.huge) or (durs == "nan" and 0/0) or tonumber(durs)
local now = 1000
local props = { duration = dur, ["time-pos"] = POS or (dur == dur and dur < 1e300 and dur * 0.37 or 100), pause = true, fullscreen = fsarg,
  mute = false, volume = 80, speed = 1, path = "/nonexistent/forged.mkv", ["media-title"] = "forged", ["container-fps"] = 25,
  ["demuxer-via-network"] = false, ["idle-active"] = false, ["playlist-count"] = 1, ["estimated-frame-number"] = 100 }
local timers, observers, overlays, events = {}, {}, {}, {}
local function T(cb, iv, periodic) local t = { cb = cb, timeout = iv, on = true, periodic = periodic }
  function t:kill() self.on = false end; function t:resume() self.on = true end; function t:stop() self.on = false end
  function t:is_enabled() return self.on end; timers[#timers + 1] = t; return t end
mp = setmetatable({
  get_time = function() return now end,
  get_property = function(k, d) local v = props[k]; if v == nil then return d end; return tostring(v) end,
  get_property_number = function(k, d) local v = props[k]; if type(v) == "number" then return v end; return d end,
  get_property_bool = function(k, d) local v = props[k]; if type(v) == "boolean" then return v end; return d end,
  get_property_native = function(k, d) local v = props[k]; if v == nil then return d end; return v end,
  get_osd_size = function() return W, H end,
  create_osd_overlay = function() local o = { data = "", n = 0 }; function o:update() self.n = self.n + 1; overlays[self] = self.data end
    function o:remove() overlays[self] = nil end; overlays[#overlays + 1] = o; return o end,
  add_periodic_timer = function(iv, cb) return T(cb, iv, true) end,
  add_timeout = function(iv, cb) return T(cb, iv, false) end,
  observe_property = function(k, _, cb) observers[#observers + 1] = { k, cb } end,
  register_event = function(k, cb) events[#events + 1] = { k, cb } end,
  get_script_name = function() return "omaraptor-hud" end,
  command_native = function() return {} end,
}, { __index = function() return function() end end })
package.preload["mp.options"] = function() return { read_options = function() end } end
package.preload["mp.utils"] = function() return { format_json = function() return "{}" end, subprocess = function() return { status = 0, stdout = "" } end,
  parse_json = function() return nil end, join_path = function(a, b) return a .. "/" .. b end, getcwd = function() return "/tmp" end,
  file_info = function() return nil end, split_path = function(p) return "/tmp/", p end, get_env_list = function() return {} end } end
package.preload["mp.msg"] = function() return setmetatable({}, { __index = function() return function() end end }) end
package.preload["mp.input"] = function() error("no input") end
package.preload["mp.assdraw"] = function() error("not used") end
dofile(script)
for _, o in ipairs(observers) do if o[1] == "pause" then o[2]("pause", true) end end
for i = 1, 40 do now = now + 0.05; for _, t in ipairs(timers) do if t.on and t.timeout and t.timeout <= 0.05 then t.cb() end end end
local main = overlays[1]
local tick
for _, t in ipairs(timers) do if t.periodic and t.timeout == 0.5 then tick = t end end
collectgarbage("collect"); local m0 = collectgarbage("count")
local t0 = os.clock(); local peak = m0
for i = 1, frames do now = now + 0.04; tick.cb(); local m = collectgarbage("count"); if m > peak then peak = m end end
local el = os.clock() - t0
local d = main.data or ""
local _, rects = d:gsub(" m %-?%d+ %-?%d+ l", "")
local f = io.open(os.getenv("ASSOUT") or "/dev/null", "w"); f:write(d); f:close()
io.write(string.format("dur=%-8s fs=%d frames=%d  ms/frame=%.3f  peak_heap_MB=%.1f  ass_bytes=%d  rect_paths=%d\n",
  durs, fsarg and 1 or 0, frames, el * 1000 / frames, peak / 1024, #d, rects))
local st = io.open("/proc/self/status")
if st then for l in st:lines() do if l:match("^VmHWM") then io.write("   ", (l:gsub("%s+", " ")), "\n") end end; st:close() end
-- 1.0.2 drew ~167 000 rects for a 1e9 s file and ran out of memory at 1e12 s; 1.0.3 stays under ~800
if #d > 200000 or rects > 2000 then io.write("FAIL: OSD grows with the claimed duration\n"); os.exit(1) end
