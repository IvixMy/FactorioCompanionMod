-- Ore prospecting for the Companion companion.
--
-- Only looks at areas the player's force has CHARTED (what the map shows).
-- It reads the real ore entities inside charted chunks, groups them into
-- patches, and ranks them: big surface area first, then closeness to spawn.
--
-- API:
--   M.start(player, ore_name)   begin a (time-sliced) scan of the player's surface
--   M.on_tick()                 call every tick
--   M.get_result(player_index)  -> {ore, surface_index, patches = {...}, best = patch|nil} or nil
--   M.result_text(player_index) -> string for the GUI
-- A patch is {area, amount, x, y, distance, x0, y0, x1, y1} (x0..y1 = bounding box). `best` is what future tasks
-- (e.g. a mining task) should travel to.

local names = require("scripts.names")
local M = {}

local CELL            = 4    -- ore tiles are bucketed into 4x4 cells before clustering
local CHUNKS_PER_TICK = 80   -- how many charted chunks are scanned per tick
local MIN_PATCH_TILES = 20   -- ignore specks smaller than this
local AREA_TIER       = 0.6  -- patches with >= 60% of the largest area count as "very big";
                             -- among those, the one closest to spawn wins
local MAX_RESULTS     = 10

local function ensure()
  storage.prospecting = storage.prospecting or {}
  local s = storage.prospecting
  s.scans   = s.scans   or {}
  s.results = s.results or {}
  s.tags    = s.tags    or {}
end

function M.init() ensure() end

function M.start(player, ore)
  ensure()
  local surface, force = player.surface, player.force
  local chunks = {}
  for chunk in surface.get_chunks() do
    if force.is_chunk_charted(surface, {x = chunk.x, y = chunk.y}) then
      chunks[#chunks + 1] = {x = chunk.x, y = chunk.y}
    end
  end
  storage.prospecting.results[player.index] = nil
  storage.prospecting.scans[player.index] = {
    ore = ore, surface_index = surface.index, force_index = force.index,
    chunks = chunks, i = 1, cells = {},
  }
  return #chunks
end

local function finish(idx, scan)
  local surface = game.get_surface(scan.surface_index)
  local force = game.forces[scan.force_index]

  -- Connected components over the 4x4 cells (8-neighbourhood)
  local visited, patches = {}, {}
  for key, cell in pairs(scan.cells) do
    if not visited[key] then
      visited[key] = true
      local patch = {area = 0, amount = 0, sx = 0, sy = 0, x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge}
      local queue, head = {cell}, 1
      while queue[head] do
        local c = queue[head]
        head = head + 1
        patch.area   = patch.area + c.n
        patch.amount = patch.amount + c.amount
        patch.sx     = patch.sx + c.sx
        patch.sy     = patch.sy + c.sy
        patch.x0 = math.min(patch.x0, c.cx * CELL)
        patch.y0 = math.min(patch.y0, c.cy * CELL)
        patch.x1 = math.max(patch.x1, c.cx * CELL + CELL)
        patch.y1 = math.max(patch.y1, c.cy * CELL + CELL)
        for dx = -1, 1 do
          for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              local k = (c.cx + dx) .. "," .. (c.cy + dy)
              local nb = scan.cells[k]
              if nb and not visited[k] then
                visited[k] = true
                queue[#queue + 1] = nb
              end
            end
          end
        end
      end
      if patch.area >= MIN_PATCH_TILES then patches[#patches + 1] = patch end
    end
  end

  local spawn = force.get_spawn_position(surface)
  for _, p in ipairs(patches) do
    p.x = p.sx / p.area
    p.y = p.sy / p.area
    p.sx, p.sy = nil, nil
    p.distance = math.sqrt((p.x - spawn.x) ^ 2 + (p.y - spawn.y) ^ 2)
  end

  -- Ranking: "very big" patches first (closest to spawn first), then the rest by area
  local ranked = {}
  if #patches > 0 then
    table.sort(patches, function(a, b) return a.area > b.area end)
    local max_area = patches[1].area
    local top, rest = {}, {}
    for _, p in ipairs(patches) do
      if p.area >= max_area * AREA_TIER then top[#top + 1] = p else rest[#rest + 1] = p end
    end
    table.sort(top, function(a, b) return a.distance < b.distance end)
    for _, p in ipairs(top) do ranked[#ranked + 1] = p end
    for _, p in ipairs(rest) do ranked[#ranked + 1] = p end
    while #ranked > MAX_RESULTS do ranked[#ranked] = nil end
  end

  local result = {ore = scan.ore, surface_index = scan.surface_index, patches = ranked, best = ranked[1]}
  storage.prospecting.results[idx] = result

  -- Map tag on the best patch + chat message
  local old = storage.prospecting.tags[idx]
  if old and old.valid then old.destroy() end
  storage.prospecting.tags[idx] = nil

  local player = game.get_player(idx)
  if result.best then
    local best = result.best
    local proto = prototypes.entity[scan.ore]
    local product = proto and proto.mineable_properties.products and proto.mineable_properties.products[1]
    local tag_spec = {position = {x = best.x, y = best.y}, text = "Best " .. scan.ore}
    if product then tag_spec.icon = {type = product.type, name = product.name} end
    storage.prospecting.tags[idx] = force.add_chart_tag(surface, tag_spec)
    if player then
      player.print(names.prefix() .. string.format("best %s patch is at [gps=%d,%d,%s] (%d tiles, %d from spawn).",
        scan.ore, math.floor(best.x), math.floor(best.y), surface.name, best.area, math.floor(best.distance)))
    end
  elseif player then
    player.print(names.prefix() .. "no charted " .. scan.ore .. " found on this surface. Explore more and scan again.")
  end
end

function M.on_tick()
  local s = storage.prospecting
  if not s then return end
  for idx, scan in pairs(s.scans) do
    local surface = game.get_surface(scan.surface_index)
    if not surface then
      s.scans[idx] = nil
    else
      local last = math.min(scan.i + CHUNKS_PER_TICK - 1, #scan.chunks)
      for i = scan.i, last do
        local ch = scan.chunks[i]
        local found = surface.find_entities_filtered{
          area = {{ch.x * 32, ch.y * 32}, {ch.x * 32 + 32, ch.y * 32 + 32}},
          name = scan.ore,
        }
        for _, e in pairs(found) do
          local p = e.position
          local cx, cy = math.floor(p.x / CELL), math.floor(p.y / CELL)
          local key = cx .. "," .. cy
          local cell = scan.cells[key]
          if not cell then
            cell = {cx = cx, cy = cy, n = 0, amount = 0, sx = 0, sy = 0}
            scan.cells[key] = cell
          end
          cell.n = cell.n + 1
          cell.amount = cell.amount + e.amount
          cell.sx = cell.sx + p.x
          cell.sy = cell.sy + p.y
        end
      end
      scan.i = last + 1
      if scan.i > #scan.chunks then
        s.scans[idx] = nil
        finish(idx, scan)
      end
    end
  end
end

function M.get_result(idx)
  ensure()
  return storage.prospecting.results[idx]
end

local function fmt(n)
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

function M.result_text(idx)
  ensure()
  local scan = storage.prospecting.scans[idx]
  if scan then
    local pct = math.floor(100 * math.min(scan.i - 1, #scan.chunks) / math.max(#scan.chunks, 1))
    return "Scanning charted map for " .. scan.ore .. "... " .. pct .. "%"
  end
  local r = storage.prospecting.results[idx]
  if not r then return "No scan yet." end
  if #r.patches == 0 then
    return "No charted " .. r.ore .. " found on this surface."
  end
  local lines = {"Patches of " .. r.ore .. " (best first):"}
  for i, p in ipairs(r.patches) do
    if i > 5 then break end
    lines[#lines + 1] = string.format("%d. %s tiles | %s ore | %d from spawn | (%d, %d)",
      i, fmt(p.area), fmt(p.amount), math.floor(p.distance), math.floor(p.x), math.floor(p.y))
  end
  return table.concat(lines, "\n")
end

return M
