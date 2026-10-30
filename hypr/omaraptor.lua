-- OmaRaptor Player (omaraptor): frameless, pinned, floating 16:9 YouTube player.
-- Load it with one line at the end of ~/.config/hypr/hyprland.lua:
--   require("hypr.omaraptor")
-- Remove that line (and this file) to undo everything.

-- mpv player. A dedicated app id keeps it out of Omarchy's centered mpv rules.
o.window("^omaraptor$", {
  tag = "-default-opacity",
  float = true,
  pin = true,                -- follows you to every workspace
  keep_aspect_ratio = true,  -- SUPER+right-drag resize stays 16:9
  -- no border_size: same thin frame as every other window (general border + colors)
  no_shadow = true,
  no_dim = true,
  no_initial_focus = true,   -- doesn't steal focus from what you're doing
  opacity = "1 1",
  idle_inhibit = "always",   -- screen won't lock mid-video
  size = { "(monitor_w*32/100)", "(monitor_w*32/100*9/16)" },
  -- window_w/h here are mpv's pre-rule size, so spell the final size out (else it lands
  -- partly off-screen).
  move = { "(monitor_w-monitor_w*32/100-24)", "(monitor_h-monitor_w*32/100*9/16-24)" },
})

-- First player: "omaraptor" titles it "OmaRaptor Player | ..." when no other player is open, so it
-- maps centred at 60% of the screen width from its very first frame (no corner flash). The
-- launcher restores the normal title right after; later players keep the corner rule above.
o.window({ class = "^omaraptor$", initial_title = "^OmaRaptor Player \\| .*" }, {
  size = { "(monitor_w*60/100)", "(monitor_w*60/100*9/16)" },
  center = true,
})

-- Browser / web-app window floated by "omaraptor web" (tag added and removed by the script).
o.window({ tag = "omaraptor-web" }, {
  keep_aspect_ratio = true,
  -- no border_size: same thin frame as every other window (general border + colors)
  no_shadow = true,
  no_dim = true,
  opacity = "1 1",
  idle_inhibit = "always",
})

local omaraptor = os.getenv("HOME") .. "/.local/bin/omaraptor"

o.bind("SUPER + ALT + Y", "OmaRaptor: play copied link in a new window (mpv)", omaraptor)
-- More windows: every launch opens its own player. The HUD's "+" button (top-left) or this
-- bind opens an empty one that asks for a link. Swap keeps the old "replace the video" behaviour.
o.bind("SUPER + CTRL + ALT + N", "OmaRaptor: new empty window (paste a link)", omaraptor .. " new")
o.bind("SUPER + CTRL + ALT + V", "OmaRaptor: swap video in current player", omaraptor .. " swap")
-- Controls below act on ONE player: the focused omaraptor window, else the last one you used.
o.bind("SUPER + ALT + W", "OmaRaptor: float focused YouTube window (toggle)", omaraptor .. " web")
o.bind("SUPER + ALT + SHIFT + Y", "OmaRaptor: close", omaraptor .. " close")
o.bind("SUPER + CTRL + ALT + Y", "OmaRaptor: next corner", omaraptor .. " corner next")
o.bind("SUPER + CTRL + ALT + bracketright", "OmaRaptor: bigger", omaraptor .. " size larger")
o.bind("SUPER + CTRL + ALT + bracketleft", "OmaRaptor: smaller", omaraptor .. " size smaller")
o.bind("SUPER + CTRL + ALT + S", "OmaRaptor: cycle small / medium / large", omaraptor .. " size cycle")
-- Move the player from anywhere. (SUPER+ALT+arrows is Omarchy's "move window to group".)
o.bind("SUPER + CTRL + ALT + LEFT", "OmaRaptor: move left", omaraptor .. " nudge left", { repeating = true })
o.bind("SUPER + CTRL + ALT + RIGHT", "OmaRaptor: move right", omaraptor .. " nudge right", { repeating = true })
o.bind("SUPER + CTRL + ALT + UP", "OmaRaptor: move up", omaraptor .. " nudge up", { repeating = true })
o.bind("SUPER + CTRL + ALT + DOWN", "OmaRaptor: move down", omaraptor .. " nudge down", { repeating = true })
-- SUPER+ALT+F is Omarchy's "Full width", so fullscreen gets the omaraptor CTRL+ALT family.
o.bind("SUPER + CTRL + ALT + F", "OmaRaptor: toggle fullscreen", omaraptor .. " fullscreen")
o.bind("SUPER + ALT + PERIOD", "OmaRaptor: next video", omaraptor .. " next")

-- Drag any window edge to resize it (Omarchy ships this off). Hyprland has no per-window
-- switch, so it's global; the grab zone is Hyprland's default 15 px around each window.
-- The omaraptor rule above keeps 16:9 while you drag. Delete these lines to turn it off again.
hl.config({ general = { resize_on_border = true } })
-- Hyprland refuses fullscreen on pinned windows by default; omaraptor is pinned, so allow it
-- (double-click, f, and SUPER+CTRL+ALT+F all need this).
hl.config({ binds = { allow_pin_fullscreen = true } })

-- Playback, from anywhere (mpv does not need focus; sent over its IPC socket).
-- SUPER+ALT+comma is Omarchy's "dismiss last notification", so seeking uses B / N instead.
o.bind("SUPER + ALT + P", "OmaRaptor: play / pause", omaraptor .. " pause")
o.bind("SUPER + ALT + M", "OmaRaptor: mute", omaraptor .. " mute")
o.bind("SUPER + ALT + B", "OmaRaptor: back 10 s", omaraptor .. " back")
o.bind("SUPER + ALT + N", "OmaRaptor: forward 10 s", omaraptor .. " fwd")
