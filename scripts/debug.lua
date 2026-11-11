-- Debug output, switched by the per-player setting "Companion: debug messages" (ec-debug).
-- say():  chat message + log line.   mark(): a dot (and label) on the map for a while.

local names = require("scripts.names")
local M = {}

function M.enabled(player)
  local s = settings.get_player_settings(player)["ec-debug"]
  return s ~= nil and s.value == true
end

function M.say(player, msg)
  if not M.enabled(player) then return end
  player.print("[" .. names.get() .. "] " .. msg)
  log("[engineer-companion] " .. msg)
end

function M.mark(player, surface, pos, color, text, ttl, radius)
  if not M.enabled(player) then return end
  ttl = ttl or 1800
  rendering.draw_circle{
    color = color, radius = radius or 0.4, filled = true, target = pos,
    surface = surface, players = {player}, time_to_live = ttl,
  }
  if text then
    rendering.draw_text{
      text = text, color = color, scale = 0.7, target = {pos.x, pos.y - 1},
      surface = surface, players = {player}, time_to_live = ttl,
    }
  end
end

-- "reason=count, reason=count" for a table of counters.
function M.counts(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. t[k] end
  return #out > 0 and table.concat(out, ", ") or "none"
end

return M
