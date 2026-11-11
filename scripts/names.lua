-- The companion's display name (runtime-global setting "ec-companion-name", default "Companion").
-- No dependencies, so any script can require it.

local M = {}

M.DEFAULT = "Companion"

function M.get()
  local s = settings and settings.global and settings.global["ec-companion-name"]
  local v = s and s.value
  if type(v) ~= "string" then return M.DEFAULT end
  v = v:match("^%s*(.-)%s*$")
  if v == "" then return M.DEFAULT end
  return v
end

-- "Companion: " (chat / log prefix)
function M.prefix()
  return M.get() .. ": "
end

return M
