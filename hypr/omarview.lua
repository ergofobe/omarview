-- Top-right hot corner for Omarview.
-- Hyprland reports monitor width and height in physical pixels and the cursor
-- in logical pixels, so the corner is measured against width / scale.
-- The corner starts latched when the pointer is already there, so reloading
-- the config does not open the overview.

local ZONE = 8
local DWELL_HITS = 4

local function in_corner()
  local pos = hl.get_cursor_pos()
  local mon = hl.get_monitor_at_cursor()
  if not pos or not mon or not mon.scale or mon.scale == 0 or not mon.width then
    return false
  end

  local right = mon.x + (mon.width / mon.scale)
  local top = mon.y
  return pos.x >= right - ZONE and pos.y <= top + ZONE
end

if _G.omarview_hotcorner and _G.omarview_hotcorner.set_enabled then
  _G.omarview_hotcorner:set_enabled(false)
end

_G.omarview_generation = (_G.omarview_generation or 0) + 1
local generation = _G.omarview_generation
local hits = 0
local latched = in_corner()

_G.omarview_hotcorner = hl.timer(function()
  if generation ~= _G.omarview_generation then
    return
  end

  if in_corner() then
    if latched then
      return
    end
    hits = hits + 1
    if hits >= DWELL_HITS then
      latched = true
      hits = 0
      hl.exec_cmd("omarchy-shell -q shell toggle omarview")
    end
  else
    hits = 0
    latched = false
  end
end, { timeout = 50, type = "repeat" })

-- Pop in without a compositor fade, the same way the other shell overlays do.
hl.layer_rule({
  match = { namespace = "^omarview$" },
  no_anim = true,
  animation = "none",
})
