-- Grid geometry helpers: quarter-turn rotation, entity footprints, fluidbox connection points.

local M = {}

local config = require("scripts.layout_config")

local D = defines.direction
local DIR_TURNS = {[D.north] = 0, [D.east] = 1, [D.south] = 2, [D.west] = 3}
local TURN_DIRS = {[0] = D.north, [1] = D.east, [2] = D.south, [3] = D.west}

function M.dir_to_turns(direction) return DIR_TURNS[direction] or 0 end
function M.turns_to_dir(turns) return TURN_DIRS[turns % 4] end

-- Rotate a vector clockwise by quarter turns (north -> east -> south -> west). y points down.
function M.rotate(x, y, turns)
  for _ = 1, turns % 4 do x, y = -y, x end
  return x, y
end

-- Unit vector along the dominant axis.
function M.unit(x, y)
  if math.abs(x) > math.abs(y) then return (x > 0) and 1 or -1, 0 end
  return 0, (y > 0) and 1 or -1
end

function M.vec_to_dir(x, y)
  local ux, uy = M.unit(x, y)
  if ux == 1 then return D.east elseif ux == -1 then return D.west
  elseif uy == 1 then return D.south else return D.north end
end

local function round_half(v) return math.floor(v * 2 + 0.5) / 2 end

-- Tile size of an entity facing north.
function M.footprint(name)
  local p = prototypes.entity[name]
  if not p then return 1, 1 end
  local w, h = p.tile_width, p.tile_height
  if not (w and h) then
    local bb = p.collision_box
    w = math.max(1, math.ceil(bb.right_bottom.x - bb.left_top.x - 0.01))
    h = math.max(1, math.ceil(bb.right_bottom.y - bb.left_top.y - 0.01))
  end
  return w, h
end

-- Bounding box (tile aligned, grown by `margin`) of a list of {name, x, y, direction} entries.
function M.bbox_of(entries, margin)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(entries) do
    local w, h = M.footprint(e.name)
    if e.direction == D.east or e.direction == D.west then w, h = h, w end
    x0 = math.min(x0, e.x - w / 2); x1 = math.max(x1, e.x + w / 2)
    y0 = math.min(y0, e.y - h / 2); y1 = math.max(y1, e.y + h / 2)
  end
  margin = margin or 0
  return math.floor(x0 - margin), math.floor(y0 - margin), math.ceil(x1 + margin), math.ceil(y1 + margin)
end

-- Raw fluidbox connection list of a prototype for a facing direction:
-- {fb = fluidbox index, count = connections in that fluidbox, x, y} (position as stored in the prototype).
function M.raw_connections(name, direction)
  local out = {}
  local proto = prototypes.entity[name]
  if not proto then return out end
  local ok, fbs = pcall(function() return proto.fluidbox_prototypes end)
  if not (ok and fbs) then return out end
  local turns = DIR_TURNS[direction] or 0
  for i, fb in ipairs(fbs) do
    local conns = fb.pipe_connections
    for _, pc in ipairs(conns) do
      local p = pc.positions and pc.positions[turns + 1]
      if not p and pc.position then
        local px, py = pc.position.x or pc.position[1], pc.position.y or pc.position[2]
        local rx, ry = M.rotate(px, py, turns)
        p = {x = rx, y = ry}
      end
      if p then
        out[#out + 1] = {fb = fb.index or i, count = #conns, x = p.x or p[1], y = p.y or p[2]}
      end
    end
  end
  return out
end

-- Prototypes can store a connection position in different ways: as the tile OUTSIDE the entity
-- (the neighbour's centre), as the tile inside it, or on its edge. The steam engine (3 x 5, one
-- connection at each end) tells which one is in use: its end connection is 3 tiles from the
-- centre when it is the neighbour tile, 2 when it is the inner tile, 2.5 on the edge.
-- Returns how far to move a stored position outwards to reach the neighbour tile centre.
local convention_delta
function M.position_delta()
  if config.fluidbox_delta ~= nil then return config.fluidbox_delta end
  if convention_delta then return convention_delta end
  convention_delta = 0
  local far = 0
  for _, c in ipairs(M.raw_connections("steam-engine", D.north)) do
    far = math.max(far, math.abs(c.x), math.abs(c.y))
  end
  if far > 0 then
    local w, h = M.footprint("steam-engine")
    local half = math.max(w, h) / 2
    convention_delta = round_half(half + 0.5 - far) -- neighbour tile centre is half + 0.5 from the middle
  end
  return convention_delta
end

-- Fluidbox connection points of an entity prototype for a facing direction.
-- Returns a list of {fb = fluidbox index, count = connections in that fluidbox,
--   x, y = centre of the NEIGHBOURING tile the connection leads to (relative to the entity centre),
--   dx, dy = unit vector pointing out of the entity through the connection}.
function M.connections(name, direction)
  local delta = M.position_delta()
  local out = {}
  for _, c in ipairs(M.raw_connections(name, direction)) do
    local dx, dy = M.unit(c.x, c.y) -- the connection sits on the side its largest coordinate points to
    out[#out + 1] = {
      fb = c.fb, count = c.count, dx = dx, dy = dy,
      x = round_half(c.x + dx * delta), y = round_half(c.y + dy * delta),
    }
  end
  return out
end

-- Text lines describing the raw and computed connections of an entity (for /engineer-connections).
function M.describe(name)
  local lines = {}
  local proto = prototypes.entity[name]
  if not proto then return {name .. ": no such entity"} end
  local w, h = M.footprint(name)
  local bb = proto.collision_box
  lines[#lines + 1] = string.format("%s: footprint %dx%d, collision box (%.2f, %.2f) - (%.2f, %.2f)",
    name, w, h, bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y)
  for _, dir in ipairs({D.north, D.east, D.south, D.west}) do
    local raw = {}
    for _, c in ipairs(M.raw_connections(name, dir)) do
      raw[#raw + 1] = string.format("fb%d(%.2f,%.2f)", c.fb, c.x, c.y)
    end
    local comp = {}
    for _, c in ipairs(M.connections(name, dir)) do
      comp[#comp + 1] = string.format("fb%d neighbour(%.1f,%.1f) out(%d,%d)", c.fb, c.x, c.y, c.dx, c.dy)
    end
    lines[#lines + 1] = string.format("  dir %d  raw: %s  ->  %s", dir, table.concat(raw, " "), table.concat(comp, "; "))
  end
  return lines
end

return M
