-- omaraptor-autoplay.lua: YouTube-style autoplay for omaraptor.
-- Playlist links play through (mpv.conf: yes-playlist). When the current video is the last
-- entry, the next pick is fetched and appended, so the queue never runs dry: YouTube's Mix
-- for it (watch?v=ID&list=RDID via yt-dlp) when there is one, else the watch page's "up next".
--   script-message omaraptor-autoplay next   skip to the next video now
local utils = require "mp.utils"
local played, fetching, want_skip = {}, false, false
local mix_cache = {}   -- seed id -> list of ids

local function yt_id(url)
  if not url then return nil end
  return url:match("[?&]v=([%w_-]+)") or url:match("youtu%.be/([%w_-]+)")
      or url:match("/shorts/([%w_-]+)") or url:match("/live/([%w_-]+)")
end
local function cur_id()
  return yt_id(mp.get_property("path")) or yt_id(mp.get_property("stream-open-filename"))
end
local function is_last()
  local pos, n = mp.get_property_number("playlist-pos", 0), mp.get_property_number("playlist-count", 0)
  return pos >= n - 1
end
local function queued()
  local q = {}
  for _, e in ipairs(mp.get_property_native("playlist") or {}) do
    local id = yt_id(e.filename); if id then q[id] = true end
  end
  return q
end

local function pick(ids)
  local q = queued()
  for _, id in ipairs(ids) do
    if not played[id] and not q[id] then return id end
  end
end

local function append(id)
  mp.commandv("loadfile", "https://www.youtube.com/watch?v=" .. id, "append")
  if want_skip then want_skip = false; mp.commandv("playlist-next", "force") end
end

local function fetch_next()
  local id = cur_id()
  if not id or fetching or not is_last() then return end
  if mix_cache[id] then local n = pick(mix_cache[id]); if n then return append(n) end end
  fetching = true
  local function done(ids)
    fetching = false
    mix_cache[id] = ids
    if cur_id() ~= id or not is_last() then return end   -- moved on meanwhile
    local n = pick(ids)
    if n then append(n) else want_skip = false; mp.msg.warn("autoplay: nothing up next") end
  end
  local function related()  -- fallback: the watch page's "up next" sidebar (first = autoplay pick)
    mp.command_native_async({
      name = "subprocess", capture_stdout = true, playback_only = false,
      args = { "curl", "-sL", "--compressed", "--max-time", "15", "-H", "Accept-Language: en-US",
               "-A", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36",
               "-b", "CONSENT=YES+1", "https://www.youtube.com/watch?v=" .. id },
    }, function(ok, r)
      local ids, seen = {}, {}
      if ok and r and r.status == 0 then
        local html = r.stdout or ""
        for v in html:gmatch('"contentId":"([%w_-]+)","contentType":"LOCKUP_CONTENT_TYPE_VIDEO"') do
          if v ~= id and not seen[v] then seen[v] = true; ids[#ids + 1] = v end
        end
        for v in html:gmatch('"compactVideoRenderer":{"videoId":"([%w_-]+)"') do
          if v ~= id and not seen[v] then seen[v] = true; ids[#ids + 1] = v end
        end
      end
      done(ids)
    end)
  end
  -- Music and many popular videos have a YouTube Mix (what youtube.com autoplays); try it first.
  mp.command_native_async({
    name = "subprocess", capture_stdout = true, capture_stderr = true, playback_only = false,
    args = { "yt-dlp", "--flat-playlist", "--print", "id", "--playlist-end", "30",
             "https://www.youtube.com/watch?v=" .. id .. "&list=RD" .. id },
  }, function(ok, r)
    local ids = {}
    if ok and r and r.status == 0 then
      for line in (r.stdout or ""):gmatch("[^\n]+") do if line ~= id then ids[#ids + 1] = line end end
    end
    if #ids > 0 then done(ids) else related() end
  end)
end

mp.register_event("file-loaded", function()
  local id = cur_id(); if id then played[id] = true end
  local t = mp.get_property("media-title", "")
  mp.commandv("script-message", "omaraptor-hud", "title", t)
  fetch_next()
end)
mp.observe_property("playlist-count", "number", function() if mp.get_property("path") then fetch_next() end end)

mp.register_script_message("omaraptor-autoplay", function(cmd)
  if cmd == "next" then
    if is_last() then
      want_skip = true; mp.osd_message("Up next…", 1); fetch_next()
    else
      mp.commandv("playlist-next", "force")
    end
  end
end)
