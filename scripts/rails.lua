-- Rail safety for driven vehicles (used by scripts/vehicles.lua).
--
--   * on_rail(v)  is any part of the vehicle on a rail? A vehicle must never stop (or get out) there.
--   * guard(...)  looks ahead along the route for a place where it crosses rails. When a train is near enough to
--                 reach that crossing before the vehicle could be across, the vehicle slows down and HOLDS in front
--                 of the first rail (never on it). When the trains have passed or stopped, it crosses.
--
-- A train counts as dangerous when it is moving (or about to start moving along its path) and one of its cars is
-- closer to the crossing than  safety + speed * (time the vehicle needs to cross + the "train look-ahead" setting).
-- Trains standing still (waiting at a station or a signal) are not a reason to wait.
--
-- Once the vehicle is on the rails, or too close to the first rail to stop in front of it, it is "committed" and
-- keeps going: stopping in the middle of a crossing is the worst thing it could do.

local M = {}

M.RAIL_TYPES  = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail"}
M.STOCK_TYPES = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"}

M.HORIZON        = 45     -- tiles of route examined ahead
M.RAIL_REACH     = 2.2    -- a route point this close to a rail counts as on the rails
M.STOP_GAP       = 1.5    -- tiles between the vehicle's body and the first rail when waiting
M.APPROACH_SPEED = 0.14   -- tiles/tick (about 30 km/h) near a crossing
M.BRAKE_DECEL    = 0.003  -- tiles/tick^2 assumed for "can I still stop in front of the rail"
M.CROSS_SPEED    = 0.06   -- tiles/tick assumed average while crossing from a standstill
M.SAFETY         = 15     -- tiles added around the crossing when looking for trains
M.PLAN_INTERVAL  = 10     -- ticks
M.MAX_WAIT       = 18000  -- ticks (5 min): after that, cross anyway rather than wait for ever

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------
-- Facts about the vehicle
---------------------------------------------------------------------

-- Radius of the circle around the whole vehicle (its longest half extent) times the size factor.
function M.body_radius(v, size)
  local box = v.prototype.collision_box
  local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
  local lx, ly = lt.x or lt[1], lt.y or lt[2]
  local rx, ry = rb.x or rb[1], rb.y or rb[2]
  return math.max(math.abs(lx), math.abs(rx), math.abs(ly), math.abs(ry)) * (size or 1)
end

local on_rail_cache = {}
-- true when the vehicle's collision box touches a rail
function M.on_rail(v)
  local key = v.unit_number or 0
  local hit = on_rail_cache[key]
  if hit and hit.tick == game.tick then return hit.value end
  local value = false
  local ok, n = pcall(v.surface.count_entities_filtered, v.surface,
    {area = v.bounding_box, type = M.RAIL_TYPES, limit = 1})
  if ok and n and n > 0 then value = true end
  on_rail_cache[key] = {tick = game.tick, value = value}
  return value
end

---------------------------------------------------------------------
-- Looking ahead
---------------------------------------------------------------------

local function rail_near(surface, pos)
  local ok, n = pcall(surface.count_entities_filtered, surface,
    {position = pos, radius = M.RAIL_REACH, type = M.RAIL_TYPES, limit = 1})
  return ok and n and n > 0
end

-- The first stretch of the route that is on rails: {enter = index, exit = index, span = tiles, center = position}
local function build_plan(v, r, list, body)
  local surface = v.surface
  local j = r.index
  local d = dist(v.position, list[j])
  local enter, exit_
  local free_run = 0
  while list[j] and d <= M.HORIZON do
    if rail_near(surface, list[j]) then
      enter = enter or j
      exit_ = j
      free_run = 0
    elseif enter then
      free_run = free_run + (list[j - 1] and dist(list[j - 1], list[j]) or 0)
      if free_run > body * 2 then break end -- clear of the tracks (a second parallel track is part of the same crossing)
    end
    if list[j + 1] then d = d + dist(list[j], list[j + 1]) end
    j = j + 1
  end
  if not enter then return nil end
  local span = 0
  for k = enter, exit_ - 1 do span = span + dist(list[k], list[k + 1]) end
  local a, b = list[enter], list[exit_]
  return {enter = enter, exit = exit_, span = span, center = {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}}
end

-- path distance from the vehicle to waypoint `to`
local function path_distance(v, list, from, to)
  local d = dist(v.position, list[from])
  for k = from, to - 1 do
    if not list[k + 1] then break end
    d = d + dist(list[k], list[k + 1])
  end
  return d
end

-- is a train going to be at this crossing? returns true plus a short description, or false
local function train_danger(v, plan, body, train_ticks)
  local clear_ticks = (plan.span + body * 3 + M.STOP_GAP) / M.CROSS_SPEED
  local horizon = clear_ticks + train_ticks
  local reach = math.min(450, M.SAFETY + plan.span / 2 + 1.5 * horizon)
  local ok, stock = pcall(v.surface.find_entities_filtered, v.surface,
    {position = plan.center, radius = reach, type = M.STOCK_TYPES})
  if not (ok and stock) then return false end
  for _, s in pairs(stock) do
    if s.valid then
      local t = s.train
      if t and t.valid then
        local sp = math.abs(t.speed or 0)
        local moving = sp > 0.003 or t.state == defines.train_state.on_the_path
        if moving then
          local limit = M.SAFETY + plan.span / 2 + sp * horizon
          local d = dist(s.position, plan.center)
          if d <= limit then
            return true, string.format("a train is %d tiles from the crossing at %d km/h", math.floor(d), math.floor(sp * 216))
          end
        end
      end
    end
  end
  return false
end

---------------------------------------------------------------------
-- Public
---------------------------------------------------------------------

-- Returns nil (nothing to do) or a table {cap = max speed (tiles/tick) or nil, hold = true to stand still, why = text}.
-- r: the ride state (route in r.waypoints / r.index); body: M.body_radius(); train_seconds: look-ahead for trains.
function M.guard(v, r, body, train_seconds)
  local list = r.waypoints
  if not list or not list[r.index] then return nil end
  local st = r.rail
  if not st then st = {}; r.rail = st end

  -- on the rails already: never stop here
  if M.on_rail(v) then
    st.hold_since = nil
    return {cap = nil, hold = false}
  end

  -- (re)plan: only now and then, it asks the game about every route point
  if st.plan and r.index > st.plan.exit then st.plan = nil; st.planned = nil end
  if (not st.planned) or game.tick - st.planned >= M.PLAN_INTERVAL then
    if not (st.plan and r.index > st.plan.enter) then -- not while crossing
      st.plan = build_plan(v, r, list, body)
    end
    st.planned = game.tick
  end
  local plan = st.plan
  if not plan then st.hold_since = nil; return nil end
  if r.index > plan.enter then return {cap = nil, hold = false} end -- crossing in progress: keep going

  local d_enter = path_distance(v, list, r.index, plan.enter)
  local d_hold = d_enter - (body + M.STOP_GAP) -- how far until the vehicle must stand to be clear of the rail
  local res = {cap = M.APPROACH_SPEED}

  if (not st.danger_tick) or game.tick - st.danger_tick >= M.PLAN_INTERVAL then
    st.danger_tick = game.tick
    st.danger, st.why = train_danger(v, plan, body, train_seconds * 60)
  end

  if st.danger then
    st.hold_since = st.hold_since or game.tick
    if game.tick - st.hold_since > M.MAX_WAIT then
      res.why = "waited too long for the train: crossing anyway"
      return res
    end
    local speed = math.abs(v.speed or 0)
    local stop_dist = speed * speed / (2 * M.BRAKE_DECEL)
    if speed < 0.02 or d_hold + 1 >= stop_dist then
      res.cap = math.min(res.cap, 0.02 + math.max(d_hold, 0) * 0.012)
      if d_hold <= 0.5 then res.hold = true end
      res.why = "waiting for a train: " .. (st.why or "")
    else
      res.why = "too close to the rails to stop: crossing"
    end
  else
    st.hold_since = nil
  end
  return res
end

return M
