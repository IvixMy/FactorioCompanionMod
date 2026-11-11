-- Route simplification for driven vehicles (used by scripts/vehicles.lua).
--
-- The pathfinder returns a route made of many small steps that follows its search grid: it zig-zags and takes
-- detours that are not needed. This module shortens it ("string pulling"):
--
--   * from the current anchor point it looks for the FARTHEST route point that can be reached in a straight line,
--     i.e. no obstacle comes closer to that line than R (R = the same clearance the pathfinder was asked for:
--     the vehicle's size * size setting * body scale + steering margin),
--   * that point becomes the new anchor, and so on until the end of the route,
--   * finally the shortened route is filled in again with points every few tiles, so everything that reads the
--     route point by point (aim point, bend detection, the rail check) keeps working as before.
--
-- Obstacles are the same ones the steering layer uses (what collides with the vehicle's own collision mask).
-- The work is spread over ticks: ONE anchor per call of M.step (one area query + pure Lua tests).
--
-- Usage:  local s = shortcut.new(list)
--         each tick:  if shortcut.step(s, vehicle, companion, R) then  use s.result  end

local steering = require("scripts.steering")

local M = {}

M.MAX_SEGMENT    = 50    -- tiles: longest straight stretch that is tried
M.CANDIDATE_STEP = 2     -- route points skipped between two candidates (counting down from the farthest)
M.MIN_SPACING    = 0.75  -- tiles between points of the final route (the original average spacing, clamped)
M.MAX_SPACING    = 3

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------
-- Geometry: distance between a segment and an axis aligned box
---------------------------------------------------------------------

local function point_segment(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = 0
  if l2 > 1e-9 then
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    t = math.max(0, math.min(1, t))
  end
  local qx, qy = ax + dx * t, ay + dy * t
  return math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end

local function point_box(x, y, box)
  local dx = math.max(box.l - x, 0, x - box.r)
  local dy = math.max(box.t - y, 0, y - box.b)
  return math.sqrt(dx * dx + dy * dy)
end

-- does the segment pass through the box? (slab method)
local function crosses(ax, ay, bx, by, box)
  local t0, t1 = 0, 1
  local dx, dy = bx - ax, by - ay
  if math.abs(dx) < 1e-9 then
    if ax < box.l or ax > box.r then return false end
  else
    local ta, tb = (box.l - ax) / dx, (box.r - ax) / dx
    if ta > tb then ta, tb = tb, ta end
    if ta > t0 then t0 = ta end
    if tb < t1 then t1 = tb end
    if t0 > t1 then return false end
  end
  if math.abs(dy) < 1e-9 then
    if ay < box.t or ay > box.b then return false end
  else
    local ta, tb = (box.t - ay) / dy, (box.b - ay) / dy
    if ta > tb then ta, tb = tb, ta end
    if ta > t0 then t0 = ta end
    if tb < t1 then t1 = tb end
    if t0 > t1 then return false end
  end
  return true
end

local function segment_box(ax, ay, bx, by, box)
  if crosses(ax, ay, bx, by, box) then return 0 end
  -- two convex shapes that do not touch: the closest pair involves an end point or a corner
  local d = math.min(point_box(ax, ay, box), point_box(bx, by, box))
  d = math.min(d, point_segment(box.l, box.t, ax, ay, bx, by))
  d = math.min(d, point_segment(box.r, box.t, ax, ay, bx, by))
  d = math.min(d, point_segment(box.l, box.b, ax, ay, bx, by))
  d = math.min(d, point_segment(box.r, box.b, ax, ay, bx, by))
  return d
end

-- true when no obstacle comes closer than R to the straight line a -> b
local function clear(a, b, boxes, R)
  local minx, maxx = math.min(a.x, b.x) - R, math.max(a.x, b.x) + R
  local miny, maxy = math.min(a.y, b.y) - R, math.max(a.y, b.y) + R
  for _, box in ipairs(boxes) do
    if not (box.r < minx or box.l > maxx or box.b < miny or box.t > maxy) then
      if segment_box(a.x, a.y, b.x, b.y, box) < R then return false end
    end
  end
  return true
end

---------------------------------------------------------------------
-- Filling the shortened route in again
---------------------------------------------------------------------

local function resample(path, spacing)
  local out = {{x = path[1].x, y = path[1].y}}
  local since = 0 -- distance walked since the last point written
  for k = 2, #path do
    local a, b = path[k - 1], path[k]
    local len = dist(a, b)
    local pos = 0
    while len - pos >= spacing - since do
      pos = pos + (spacing - since)
      since = 0
      local f = pos / len
      out[#out + 1] = {x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f}
    end
    since = since + (len - pos)
  end
  local last = path[#path]
  if dist(out[#out], last) > 0.1 then out[#out + 1] = {x = last.x, y = last.y} end
  return out
end

---------------------------------------------------------------------
-- Public
---------------------------------------------------------------------

-- list: the route as returned by the pathfinder (array of positions)
function M.new(list)
  local total = 0
  for k = 1, #list - 1 do total = total + dist(list[k], list[k + 1]) end
  local spacing = total / math.max(1, #list - 1)
  spacing = math.max(M.MIN_SPACING, math.min(M.MAX_SPACING, spacing))
  return {
    raw = list, n = #list, anchor = 1, spacing = spacing,
    out = {{x = list[1].x, y = list[1].y}},
    points_before = #list, length_before = total,
  }
end

local function finish(s)
  s.result = resample(s.out, s.spacing)
  local len = 0
  for k = 1, #s.result - 1 do len = len + dist(s.result[k], s.result[k + 1]) end
  s.points_after, s.length_after = #s.result, len
  s.done = true
  return true
end

-- One step of the work. v: vehicle, c: companion, R: clearance in tiles.
-- Returns true once finished (the new route is in s.result).
function M.step(s, v, c, R)
  if s.done then return true end
  local list, n, a = s.raw, s.n, s.anchor
  if a >= n then return finish(s) end

  -- farthest route point within MAX_SEGMENT (as the crow flies) of the anchor
  local jmax = a + 1
  while jmax < n and dist(list[a], list[jmax + 1]) <= M.MAX_SEGMENT do jmax = jmax + 1 end

  local pick = a + 1 -- the next point of the original route is always accepted (the pathfinder cleared it)
  if jmax > a + 1 then
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for k = a, jmax do
      local p = list[k]
      if p.x < x1 then x1 = p.x end
      if p.x > x2 then x2 = p.x end
      if p.y < y1 then y1 = p.y end
      if p.y > y2 then y2 = p.y end
    end
    local pad = R + 0.5
    local boxes = steering.obstacles(v, c, {{x1 - pad, y1 - pad}, {x2 + pad, y2 + pad}})
    local j = jmax
    while j > a + 1 do
      if clear(list[a], list[j], boxes, R) then
        pick = j
        -- candidates are tried every CANDIDATE_STEP points: see whether the one just after works too
        if pick < jmax and clear(list[a], list[pick + 1], boxes, R) then pick = pick + 1 end
        break
      end
      j = j - M.CANDIDATE_STEP
    end
  end

  s.out[#s.out + 1] = {x = list[pick].x, y = list[pick].y}
  s.anchor = pick
  if pick >= n then return finish(s) end
  return false
end

return M
