-- Steering layer for driven vehicles (used by scripts/vehicles.lua).
--
-- The pathfinder returns the SHORTEST route that merely does not collide, so it hugs every corner. This layer sits
-- between the route and the wheel: it takes the aim point chosen along the route and pushes it sideways, away from
-- obstacles (buildings, cliffs, trees, water ...) near the stretch the car is about to drive, so the car takes
-- corners wide and keeps a gap from walls.
--
-- How it works:
--   * every SCAN_INTERVAL ticks, a few sample points are laid along the line  car -> aim point
--   * obstacles are everything that collides with the VEHICLE's own collision mask in a box around that line
--     (entities by their bounding box, tiles such as water as 1x1 boxes)
--   * each obstacle closer than  R = body radius + margin  to a sample point pushes away from itself, harder the
--     deeper the sample is inside that zone
--   * only the SIDEWAYS part of the push is kept (a push along the heading would just stall the car or drag the aim
--     point behind it); opposite walls cancel out, so a narrow corridor still gets driven down the middle
--   * the result is smoothed so the wheel does not jitter, and clamped so the aim point never wanders far off the route
--   * a "pressure" value (0..1) says how squeezed the car is; the caller slows down with it
--
-- The margin is the setting ec-vehicle-steer-margin (tiles, 0 = this layer is off).

local M = {}

M.SCAN_INTERVAL = 4     -- ticks between two scans (the result is reused in between)
M.SAMPLES = {           -- {fraction of the way car -> aim point, weight}
  {0,     0.25},
  {1 / 3, 0.5},
  {2 / 3, 0.75},
  {1,     1},
}
M.PUSH_DIVISOR   = 2    -- weighted sum of pushes / this = shift of the aim point (lower = pushes harder)
M.MAX_SHIFT_PLUS = 1    -- the aim point moves at most (margin + this) tiles
M.SMOOTHING      = 0.5  -- share of the new value per scan (1 = no smoothing)

-- things that do not count as obstacles even if their collision mask overlaps
local IGNORE_TYPES = {
  ["character"] = true,
  ["gate"] = true,               -- the route may open gates
  ["entity-ghost"] = true,
  ["tile-ghost"] = true,
  ["item-entity"] = true,
  ["item-request-proxy"] = true,
}

---------------------------------------------------------------------
-- Prototype facts (derived from prototypes only, safe to cache locally)
---------------------------------------------------------------------

local proto_cache = {}

local function xy(p) return p.x or p[1], p.y or p[2] end

local function info(proto)
  local i = proto_cache[proto.name]
  if i then return i end
  local layers = {}
  local mask = proto.collision_mask
  local dict = mask and (mask.layers or mask) or {}
  for name, on in pairs(dict) do
    if on == true then layers[#layers + 1] = name end
  end
  local box = proto.collision_box
  local lx, ly = xy(box.left_top or box[1])
  local rx, ry = xy(box.right_bottom or box[2])
  local half_w = math.min(rx - lx, ry - ly) / 2
  local half_l = math.max(rx - lx, ry - ly) / 2
  -- a car is long and thin and turns in every direction: its "radius" is its HALF LENGTH (the circle around the
  -- whole body), scaled by the size setting
  local set = {}
  for _, name in ipairs(layers) do set[name] = true end
  i = {layers = layers, set = set, radius = half_l, half_w = half_w}
  proto_cache[proto.name] = i
  return i
end

---------------------------------------------------------------------
-- Obstacles
---------------------------------------------------------------------

-- list of {l, t, r, b} boxes colliding with the vehicle's mask inside `area`
-- Does the entity prototype share a collision layer with the vehicle? (checked by hand, not through the API's
-- collision_mask filter, so there is no doubt about what that filter means)
local function overlaps(e_proto, set)
  local mask = e_proto.collision_mask
  local dict = mask and (mask.layers or mask)
  if not dict then return false end
  for name, on in pairs(dict) do
    if on == true and set[name] then return true end
  end
  return false
end

local overlap_cache = {} -- [vehicle proto name][entity proto name] = bool

local function collect(v, c, area, i)
  local boxes = {}
  if #i.layers == 0 then return boxes end
  local surface = v.surface
  local cache = overlap_cache[v.name]
  if not cache then cache = {}; overlap_cache[v.name] = cache end

  local ok, ents = pcall(surface.find_entities_filtered, surface, {area = area})
  if ok and ents then
    for _, e in pairs(ents) do
      if e.valid and e ~= v and e ~= c and not IGNORE_TYPES[e.type] then
        local hit = cache[e.name]
        if hit == nil then
          hit = overlaps(e.prototype, i.set)
          cache[e.name] = hit
        end
        if hit then
          local bb = e.bounding_box
          local lx, ly = xy(bb.left_top or bb[1])
          local rx, ry = xy(bb.right_bottom or bb[2])
          boxes[#boxes + 1] = {l = lx, t = ly, r = rx, b = ry}
        end
      end
    end
  end

  local okt, tiles = pcall(surface.find_tiles_filtered, surface, {area = area, collision_mask = i.layers})
  if okt and tiles then
    for _, tile in pairs(tiles) do
      local px, py = xy(tile.position)
      boxes[#boxes + 1] = {l = px, t = py, r = px + 1, b = py + 1}
    end
  end
  return boxes
end

-- distance from (x, y) to the box, and the unit vector pointing from the box towards the point
local function from_box(box, x, y)
  local dx = math.max(box.l - x, 0, x - box.r)
  local dy = math.max(box.t - y, 0, y - box.b)
  local d = math.sqrt(dx * dx + dy * dy)
  if d > 1e-6 then
    -- nearest point of the box is (x + dx*sign...) ; the direction away from it is the opposite of (dx, dy) signs
    local sx = (x < box.l) and -1 or ((x > box.r) and 1 or 0)
    local sy = (y < box.t) and -1 or ((y > box.b) and 1 or 0)
    return d, (dx * sx) / d, (dy * sy) / d
  end
  -- the sample is inside the box: push away from its centre
  local cx, cy = (box.l + box.r) / 2, (box.t + box.b) / 2
  local ox, oy = x - cx, y - cy
  local len = math.sqrt(ox * ox + oy * oy)
  if len < 1e-6 then return 0, 1, 0 end
  return 0, ox / len, oy / len
end

---------------------------------------------------------------------
-- Scan
---------------------------------------------------------------------

-- The swept corridor: the strip of width 2*W along the line car -> aim point (W = half the vehicle's width * size +
-- margin). Every obstacle that reaches into the strip forbids a range of sideways offsets for the aim point; the
-- forbidden ranges are merged and, if the straight line (offset 0) is inside one, the nearest free offset on either
-- side is the way around it. Works for an obstacle dead ahead, where a plain push has no sideways part at all.
-- Returns nil when the line is free, else  offset, nearest_distance_along_the_line.
local function find_gap(boxes, p, ux, uy, nx, ny, len, W, reach, prefer)
  local ranges = {}
  local a_lo, a_hi = -reach * 0.5, len + reach * 0.5
  for _, box in ipairs(boxes) do
    local smin, smax, amin, amax = math.huge, -math.huge, math.huge, -math.huge
    for _, cx in ipairs({box.l, box.r}) do
      for _, cy in ipairs({box.t, box.b}) do
        local rx, ry = cx - p.x, cy - p.y
        local a, side = rx * ux + ry * uy, rx * nx + ry * ny
        if a < amin then amin = a end
        if a > amax then amax = a end
        if side < smin then smin = side end
        if side > smax then smax = side end
      end
    end
    if amax >= a_lo and amin <= a_hi then
      ranges[#ranges + 1] = {lo = smin - W, hi = smax + W, a = math.max(amin, 0)}
    end
  end
  if #ranges == 0 then return nil end
  table.sort(ranges, function(x, y) return x.lo < y.lo end)

  -- merge overlapping ranges, remember the one that contains offset 0
  local cur
  local found
  local function close()
    if cur and cur.lo < 0 and cur.hi > 0 then found = cur end
  end
  for _, rg in ipairs(ranges) do
    if cur and rg.lo < cur.hi - 0.05 then
      if rg.hi > cur.hi then cur.hi = rg.hi end
      if rg.a < cur.a then cur.a = rg.a end
    else
      close()
      cur = {lo = rg.lo, hi = rg.hi, a = rg.a}
    end
  end
  close()
  if not found then return nil end

  local cost_neg, cost_pos = -found.lo, found.hi
  -- keep going round the same side as before (no flip-flopping in front of an obstacle)
  if prefer and prefer < 0 then cost_neg = cost_neg - 0.75 elseif prefer and prefer > 0 then cost_pos = cost_pos - 0.75 end
  if cost_neg < cost_pos then return found.lo, found.a end
  return found.hi, found.a
end

local function draw_debug(v, aim, shifted, boxes, R, p, body)
  local ttl = M.SCAN_INTERVAL + 2
  local function d(kind, args)
    args.surface, args.time_to_live = v.surface, ttl
    pcall(function() rendering[kind](args) end)
  end
  for _, box in ipairs(boxes) do
    if from_box(box, p.x, p.y) < R + 6 then
      d("draw_rectangle", {color = {r = 1, g = 0.1, b = 0.1}, width = 2, filled = false,
        left_top = {box.l, box.t}, right_bottom = {box.r, box.b}})
    end
  end
  d("draw_circle", {color = {r = 1, g = 1, b = 1}, radius = 0.4, width = 2, target = aim})
  d("draw_circle", {color = {r = 0.1, g = 1, b = 0.2}, radius = 0.5, width = 3, target = shifted})
  d("draw_circle", {color = {r = 1, g = 0.9, b = 0.1}, radius = body, width = 2, target = p}) -- the vehicle's size
  d("draw_circle", {color = {r = 0.2, g = 0.6, b = 1}, radius = R, width = 1, target = p})    -- + margin
end

local function scan(v, c, aim, margin, st, debug, size)
  local p = v.position
  local dx, dy = aim.x - p.x, aim.y - p.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.5 then
    st.px, st.py, st.pressure = st.px * 0.5, st.py * 0.5, st.pressure * 0.5
    return
  end
  local ux, uy = dx / len, dy / len
  local nx, ny = -uy, ux -- sideways

  local i = info(v.prototype)
  local body = i.radius * size
  local R = body + margin

  local pad = R + 0.5
  local area = {
    {math.min(p.x, aim.x) - pad, math.min(p.y, aim.y) - pad},
    {math.max(p.x, aim.x) + pad, math.max(p.y, aim.y) + pad},
  }
  local boxes = collect(v, c, area, i)
  st.n = #boxes

  local sum_x, sum_y = 0, 0
  local closest = math.huge
  for _, s in ipairs(M.SAMPLES) do
    local sx, sy = p.x + dx * s[1], p.y + dy * s[1]
    for _, box in ipairs(boxes) do
      local d, ax, ay = from_box(box, sx, sy)
      if d < R then
        local push = (R - d) * s[2]
        sum_x, sum_y = sum_x + ax * push, sum_y + ay * push
      end
      if s[1] <= 2 / 3 and d < closest then closest = d end
    end
  end

  -- keep only the sideways part, scale, clamp
  local side = (sum_x * nx + sum_y * ny) / M.PUSH_DIVISOR
  -- never more than ~30 degrees of extra turn: the shift is limited by the distance to the aim point as well
  local max_shift = math.min(margin + M.MAX_SHIFT_PLUS, len * 0.6)
  side = math.max(-max_shift, math.min(max_shift, side))

  -- pressure: 0 = at least `margin` of free space around the body, 1 = touching
  local pressure = 0
  if closest < math.huge then
    pressure = math.max(0, math.min(1, 1 - (closest - body) / margin))
  end

  -- something in the way of the straight line? then go AROUND it (overrides the soft push)
  local W = i.half_w * size + margin
  local gap, near = find_gap(boxes, p, ux, uy, nx, ny, len, W, body, st.side)
  local blocked = gap ~= nil
  if blocked then
    local max_block = len * 0.9
    if math.abs(gap) <= max_block then
      side = gap
      st.side = (gap < 0) and -1 or 1
      pressure = math.max(pressure, (near < body * 2) and 0.9 or 0.6)
    else
      -- no way round within one aim-point length (walls on both sides?): keep the soft push and creep
      pressure = 1
    end
  else
    st.side = nil
  end
  local new_x, new_y = nx * side, ny * side

  local k = blocked and 1 or M.SMOOTHING -- react at once when something is in the way
  st.px = st.px * (1 - k) + new_x * k
  st.py = st.py * (1 - k) + new_y * k
  st.pressure = st.pressure * (1 - k) + pressure * k

  if debug then
    draw_debug(v, aim, {x = aim.x + st.px, y = aim.y + st.py}, boxes, R, p, body)
  end
end

---------------------------------------------------------------------
-- Public
---------------------------------------------------------------------

-- Boxes {l, t, r, b} of everything that collides with the vehicle inside `area` ({{x1, y1}, {x2, y2}}).
-- Used by scripts/shortcut.lua (route simplification) so it sees the same obstacles as the steering.
function M.obstacles(v, c, area)
  return collect(v, c, area, info(v.prototype))
end

-- v: the vehicle, c: the companion, aim: aim point from the route, margin: tiles (<= 0 = off),
-- state: any table that lives as long as the ride (the scan result is kept in state.steer).
-- size: multiplier on the vehicle's radius (setting ec-vehicle-steer-size / 100)
-- debug: draw obstacles (red), the aim point (white), the adjusted one (green), the vehicle's size (yellow circle)
-- and size + margin (blue circle).
-- Returns the adjusted aim point, the pressure (0..1) and how many obstacles were found near the car.
function M.adjust(v, c, aim, margin, state, debug, size)
  size = size or 1
  if not margin or margin <= 0 then return aim, 0, 0 end
  local st = state.steer
  if not st then
    st = {px = 0, py = 0, pressure = 0, tick = -1000}
    state.steer = st
  end
  if game.tick - st.tick >= M.SCAN_INTERVAL then
    st.tick = game.tick
    scan(v, c, aim, margin, st, debug, size)
  end
  return {x = aim.x + st.px, y = aim.y + st.py}, st.pressure, st.n or 0
end

return M
