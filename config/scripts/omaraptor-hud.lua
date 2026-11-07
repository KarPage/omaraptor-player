-- omaraptor-hud loader.
-- The HUD source is .assemble/hud-src-01 .. hud-src-10, in that order. Joined, they are the
-- script. install.sh writes that joined file to ~/.config/omaraptor/scripts/omaraptor-hud.lua.
-- This copy stays in the repo so a checkout can run the same bytes: the parts sit in
-- .assemble/ next to the repository root, or beside this file after a hand copy.
local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local info = debug.getinfo(1, "S").source
local path = (info:sub(1, 1) == "@") and info:sub(2) or info
local dir = path:match("^(.*)/") or "."
local parts = {}
for i = 1, 10 do
  local name = string.format("hud-src-%02d", i)
  local s = read_all(dir .. "/" .. name) or read_all(dir .. "/../../.assemble/" .. name)
  if not s then error("omaraptor-hud: missing " .. name) end
  parts[i] = s
end
local chunk, err = loadstring(table.concat(parts), "@" .. path)
if not chunk then error("omaraptor-hud: " .. tostring(err)) end
return chunk()
