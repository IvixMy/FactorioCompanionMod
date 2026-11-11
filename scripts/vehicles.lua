-- Vehicles: when its goal is far away, a vehicle (car / tank / spidertron) is near, and a drivable route can be
-- traced for it, the companion walks to the vehicle, drives it along the route and gets out a set distance from the
-- goal to carry on with its task on foot. Trains are never used (no rolling stock, so no schedules involved).
--
-- Hooked into walking: scripts/pathing.lua registers  common.walker = vehicles.wrap(pathing.walk),  so EVERY task
-- (build, fetch, mine, restock...) gets this for free. A task keeps calling walk_towards(target) each tick; this
-- layer decides whether to drive instead.
--
-- Phases (data.ride.phase):
--   checking  asking the game for a route for the VEHICLE's own bounding box + collision mask (is there room to trace
--             one?). The companion waits. No route -> no ride (cooldown) and it simply walks.
--   boarding  walks to the vehicle and takes the driver seat.
--   driving   steers along the route (cars), or sets the autopilot (spider-vehicles walk over obstacles).
--   routing   a new goal appeared while driving: waiting for the new route, staying seated.
-- The route is drawn on the map (rendering in "chart" mode) while it is used.
--
-- No vehicle near (0.19.2): scripts/vehicle_supply.lua (hooked in as M.supplier) crafts a car for a long trip
-- (materials from the chests, like any other craft) and puts it down next to the companion. A vehicle with an empty /
-- low tank is fuelled with the BEST fuel available (carried, a chest, the coal drills, or mined / chopped by hand;
-- scripts/fuel.lua) before the ride, and topped up from the carried fuel during a long one. Setting: ec-vehicle-craft.
--
-- Settings (per player): ec-vehicle-enabled, ec-vehicle-min-distance (goal is "far"), ec-vehicle-search-radius
-- (vehicle is "near"), ec-vehicle-dismount-distance, ec-vehicle-show-route, ec-vehicle-steer-margin.
--
-- Simplifying: the route from the pathfinder is shortened by scripts/shortcut.lua (straight lines between route
-- points wherever the clearance asked of the pathfinder is still kept); setting ec-vehicle-simplify.
--
-- Steering: the pathfinder's route is the shortest one and hugs corners, so the aim point taken from the route is
-- passed through scripts/steering.lua, which pushes it away from nearby obstacles (margin = ec-vehicle-steer-margin).

local common = require("scripts.common")
local debug  = require("scripts.debug")
local steering = require("scripts.steering")
local rails = require("scripts.rails")
local shortcut = require("scripts.shortcut")

local M = {}

M.TYPES = {"car", "spider-vehicle"}   -- never trains (tanks are of type "car")
M.SEARCH_COOLDOWN   = 300   -- ticks between two looks for a vehicle
M.FAIL_COOLDOWN     = 1800  -- after a failed ride attempt
M.BOARD_TIMEOUT     = 900
M.BOARD_REACH       = 3.5
M.WAYPOINT_REACHED  = 5
-- Defaults; the settings ec-vehicle-aim-distance and ec-vehicle-max-speed replace the first and scale the speeds.
M.MIN_LOOKAHEAD     = 3.5   -- tiles along the route
M.MAX_LOOKAHEAD     = 7
M.TOP_SPEED         = 0.2   -- tiles / tick (about 43 km/h)
M.BEND_SPEED        = 0.1   -- on a sharp bend
M.TURN_SPEED        = 0.07  -- while the car is not pointing at where it aims
M.NEAR_GOAL_SPEED   = 0.12  -- in the last stretch before getting out
M.MAX_ROUTE_LINES   = 120

M.supplier = nil -- scripts/vehicle_supply.lua registers itself here (it needs the planner, which needs this file)

local base_walk -- pathing.walk, set by wrap()

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function owner(data)
  for index, d in pairs(storage.companions or {}) do
    if d == data then return game.get_player(index) end
  end
  return nil
end

local function config(data)
  -- read the settings once a second, not 16 times every tick (walking asks every tick)
  local cache = data.cfg_cache
  if cache and game.tick - cache.tick < 60 then return cache.cfg end
  local player = owner(data)
  local s = player and settings.get_player_settings(player)
  local function get(name, default)
    local v = s and s[name]
    if v == nil then return default end
    return v.value
  end
  local cfg = {
    enabled = get("ec-vehicle-enabled", true),
    craft = get("ec-vehicle-craft", true),
    min_distance = get("ec-vehicle-min-distance", 120),
    search = get("ec-vehicle-search-radius", 100),
    dismount = get("ec-vehicle-dismount-distance", 25),
    show_route = get("ec-vehicle-show-route", true),
    tolerance = get("ec-vehicle-goal-tolerance", 40),
    body_scale = get("ec-vehicle-body-scale", 90),
    steer_margin = get("ec-vehicle-steer-margin", 5),
    steer_size = get("ec-vehicle-steer-size", 300) / 100,
    aim_distance = get("ec-vehicle-aim-distance", 9),
    -- override in km/h -> tiles per tick (1 tile/tick = 216 km/h); 0 = the vehicle's own top speed
    max_speed = get("ec-vehicle-max-speed", 0) / 216,
    dismount_speed = get("ec-vehicle-dismount-speed", 3) / 216,
    rail_check = get("ec-vehicle-rail-check", true),
    simplify = get("ec-vehicle-simplify", true),
    train_time = get("ec-vehicle-train-time", 10),
    debug = get("ec-debug", false),
    timeout = get("ec-vehicle-route-timeout", 30) * 60,
  }
  data.cfg_cache = {tick = game.tick, cfg = cfg}
  return cfg
end

local function dist(a, b) return math.sqrt(common.dist2(a, b)) end

-- true, or false + the reason. ignore_fuel: an empty tank is not a reason any more (it is filled before the ride)
local function usable(v, ignore_fuel)
  if not v.valid then return false, "invalid" end
  if v.get_driver() ~= nil or v.get_passenger() ~= nil then return false, "somebody is in it" end
  if v.to_be_deconstructed() then return false, "marked for deconstruction" end
  if not ignore_fuel then
    local ok, inv = pcall(v.get_fuel_inventory)
    if ok and inv and inv.is_empty() then return false, "no fuel" end
  end
  return true
end

-- Has the vehicle a fuel slot that is empty?
local function tank_empty(v)
  local ok, inv = pcall(v.get_fuel_inventory)
  return ok and inv ~= nil and inv.is_empty()
end

-- Reports to the player (when the debug setting is on), at most once per 10 s per message.
local function note(data, msg, key)
  key = key or msg
  data.ride_notes = data.ride_notes or {}
  if (data.ride_notes[key] or 0) > game.tick then return end
  data.ride_notes[key] = game.tick + 600
  local player = owner(data)
  if player then debug.say(player, "vehicle: " .. msg) end
end

-- usable vehicle nearest to the companion within `radius`; else nil plus a text saying what was seen.
local function find_vehicle(c, radius)
  local best, best_d       -- nearest with fuel in the tank
  local empty, empty_d     -- nearest with an empty tank (usable: it is fuelled before the ride)
  local seen
  local list = c.surface.find_entities_filtered{
    position = c.position, radius = radius, type = M.TYPES,
  }
  for _, v in pairs(list) do
    local d = common.dist2(v.position, c.position)
    if v.force ~= c.force then
      seen = seen or string.format("%s of force %s", v.name, v.force.name)
    else
      local ok, why = usable(v, true)
      if ok then
        if tank_empty(v) then
          if not empty or d < empty_d then empty, empty_d = v, d end
        elseif not best or d < best_d then
          best, best_d = v, d
        end
      else
        seen = string.format("%s is not usable (%s)", v.name, why)
      end
    end
  end
  if best then return best end
  if empty then return empty end
  return nil, seen or string.format("no car / tank / spidertron within %d tiles", math.floor(radius))
end

---------------------------------------------------------------------
-- Route on the map
---------------------------------------------------------------------

local function clear_lines(r)
  for _, obj in pairs(r.lines or {}) do
    if obj.valid then obj.destroy() end
  end
  r.lines = {}
end

-- Draws on the MAP (render_mode "chart"); if this version rejects that, falls back to alt-mode lines in the world.
local function draw(kind, args)
  args.render_mode = "chart"
  local ok, obj = pcall(function() return rendering[kind](args) end)
  if not ok then
    args.render_mode = nil
    args.only_in_alt_mode = true
    ok, obj = pcall(function() return rendering[kind](args) end)
  end
  return ok and obj or nil
end

local function draw_route(data, r, show)
  clear_lines(r)
  if not show then return end
  local c, v = data.entity, r.vehicle
  if not (c.valid and v.valid) then return end
  local points = {{x = v.position.x, y = v.position.y}}
  local list = r.waypoints or {r.goal}
  local step = math.max(1, math.ceil(#list / M.MAX_ROUTE_LINES))
  for i = 1, #list, step do points[#points + 1] = list[i] end
  points[#points + 1] = r.goal
  local color = {r = 1, g = 0.55, b = 0.1}
  for i = 1, #points - 1 do
    local obj = draw("draw_line", {
      color = color, width = 4, from = points[i], to = points[i + 1],
      surface = c.surface, forces = {c.force}, time_to_live = 60 * 60 * 20,
    })
    if obj then r.lines[#r.lines + 1] = obj end
  end
  local dest = draw("draw_circle", {
    color = color, radius = 2.5, width = 4, filled = false, target = r.goal,
    surface = c.surface, forces = {c.force}, time_to_live = 60 * 60 * 20,
  })
  if dest then r.lines[#r.lines + 1] = dest end
end

---------------------------------------------------------------------
-- Leaving the vehicle
---------------------------------------------------------------------

-- cooldown: ticks before the next ride is considered (nil = none)
-- Every end of a ride says why (chat, when the debug setting is on) and remembers it in data.ride_last.
function M.dismount(data, cooldown, text)
  local r = data.ride
  if not r then return end
  clear_lines(r)
  local c, v = data.entity, r.vehicle
  if v and v.valid then
    if r.spider then
      pcall(function() v.autopilot_destination = nil end)
    else
      pcall(function()
        v.riding_state = {acceleration = defines.riding.acceleration.braking, direction = defines.riding.direction.straight}
      end)
    end
  end
  if c and c.valid then
    pcall(function() c.driving = false end)
    if v and v.valid and v.get_driver() ~= nil then pcall(v.set_driver, nil) end
    c.walking_state = {walking = false}
    if text then data.status = text end
  end
  if text then
    if cooldown and cooldown >= M.FAIL_COOLDOWN then data.ride_last = text end -- only failures are remembered
    data.ride_notes = nil -- a new situation: say it even if the same words were used a moment ago
    note(data, text)
  end
  data.ride = nil
  data.nav = nil
  if cooldown then data.ride_cd = game.tick + cooldown end
end

-- Called every tick by scripts/crafting.lua: if nothing has asked to walk for a moment (the task ended, the mode
-- changed), the companion must not keep driving on its own.
function M.watchdog(data)
  local r = data.ride
  if not r then return end
  local c = data.entity
  if not (c and c.valid and r.vehicle and r.vehicle.valid) then
    clear_lines(r)
    data.ride = nil
    return
  end
  if game.tick - (r.last_walk or 0) > 60 then M.dismount(data, nil, "stopped driving (nothing asked to walk any more)") end
end

---------------------------------------------------------------------
-- Route requests
---------------------------------------------------------------------

local function xy(p) return p.x or p[1], p.y or p[2] end

-- The steering margin is also asked of the PATHFINDER: its box is inflated by the margin on every side, so the route
-- itself keeps its distance from obstacles (that is what really stops corner hugging). If no route fits, the margin is
-- halved step by step (1, 1/2, 1/4, 0) until one does.
local MARGIN_STEPS = {1, 0.5, 0.25, 0}
local function margin_scale(r) return MARGIN_STEPS[(r.margin_step or 0) + 1] or 0 end

-- true when a thinner margin could still be tried (and steps to it)
local function thinner_margin(data, r, cfg)
  if cfg.steer_margin <= 0 or (r.margin_step or 0) >= #MARGIN_STEPS - 1 then return false end
  r.margin_step = (r.margin_step or 0) + 1
  note(data, string.format("no route with a margin of %.1f tiles: trying %.2f", cfg.steer_margin * MARGIN_STEPS[r.margin_step], cfg.steer_margin * margin_scale(r)), "margin")
  return true
end

-- Clearance the pathfinder was asked for (half side of its square box, see request_route). The route simplifier
-- keeps this distance from every obstacle, so a shortcut is never tighter than the original route.
local function path_half(v, cfg, r)
  local box = v.prototype.collision_box
  local lx, ly = xy(box.left_top or box[1])
  local rx, ry = xy(box.right_bottom or box[2])
  local half = math.max(math.abs(lx), math.abs(rx), math.abs(ly), math.abs(ry)) * cfg.steer_size
  local k = math.max(0.3, math.min(2.5, cfg.body_scale / 100 + (r.extra_clearance or 0)))
  return half * k + cfg.steer_margin * margin_scale(r)
end

-- One slice of the route simplification (called every tick while r.simplify exists). When it is finished the
-- shortened route is published exactly like a route straight from the pathfinder (r.waypoints, r.index, r.found).
local function simplify_step(data, r, cfg)
  local s = r.simplify
  if not s then return end
  local ok, done = pcall(shortcut.step, s, r.vehicle, data.entity, path_half(r.vehicle, cfg, r))
  if not ok then -- never lose a route because of this: use the original one
    note(data, "route simplification failed (" .. tostring(done) .. "): using the original route", "simplify")
    s.result, s.points_after, s.length_after = s.raw, s.points_before, s.length_before
    done = true
  end
  if done then
    r.waypoints, r.index, r.found = s.result, 1, true
    r.simplify = nil
    note(data, string.format("route simplified: %d -> %d points, %d -> %d tiles",
      s.points_before, s.points_after, math.floor(s.length_before), math.floor(s.length_after)), "simplify")
  end
end

local function request_route(data, r)
  local c, v = data.entity, r.vehicle
  local cfg = config(data)
  local proto = v.prototype
  local box = proto.collision_box
  local lx, ly = xy(box.left_top or box[1])
  local rx, ry = xy(box.right_bottom or box[2])
  local k = math.max(0.3, math.min(2.5, cfg.body_scale / 100 + (r.extra_clearance or 0)))
  -- The pathfinder's box does not turn with the vehicle. The prototype box is long in one direction only, so a car
  -- driving sideways would be checked with a box of the wrong shape. Use a SQUARE with the vehicle's longest half
  -- extent (it fits every heading), scaled by the size setting.
  local half = math.max(math.abs(lx), math.abs(rx), math.abs(ly), math.abs(ry)) * cfg.steer_size
  lx, ly, rx, ry = -half, -half, half, half -- (the body-scale setting k is applied below)
  local m = cfg.steer_margin * margin_scale(r)
  local ok, id = pcall(function()
    return c.surface.request_path{
      bounding_box = {left_top = {x = lx * k - m, y = ly * k - m}, right_bottom = {x = rx * k + m, y = ry * k + m}},
      collision_mask = proto.collision_mask,
      start = v.position,
      goal = r.goal,
      force = c.force,
      radius = cfg.tolerance,           -- the route may end this far from the goal (the goal itself may be built over)
      entity_to_ignore = v,             -- else the vehicle blocks its own start
      can_open_gates = true,
      path_resolution_modifier = 0,
      pathfind_flags = {cache = false, low_priority = true}, -- a long search must not hog the pathfinder (frame rate)
    }
  end)
  if ok and id then
    r.req, r.req_tick = id, game.tick
    return true
  end
  note(data, "could not even ask for a route: " .. tostring(id))
  return false
end

-- on_script_path_request_finished (pathing.lua forwards every answer here first). Returns true when it was ours.
function M.on_path_finished(e)
  for _, data in pairs(storage.companions or {}) do
    local r = data.ride
    if r and r.req == e.id then
      r.req = nil
      if e.path and #e.path > 1 then
        local list = {}
        for i = 2, #e.path do list[#list + 1] = e.path[i].position end
        if #list > 2 and config(data).simplify and r.vehicle and r.vehicle.valid then
          r.simplify = shortcut.new(list) -- shortened over the next ticks; r.found is set when done
        else
          r.waypoints, r.index, r.found = list, 1, true
        end
      elseif e.try_again_later then
        r.retry = true
        r.retries = (r.retries or 0) + 1
      else
        r.failed = true
      end
      return true
    end
  end
  return false
end

---------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------

local function steer(v, aim, speed_cap, reverse, turn_speed, slack)
  local p = v.position
  local o = math.atan2(aim.x - p.x, -(aim.y - p.y)) / (2 * math.pi)
  if o < 0 then o = o + 1 end
  local diff = ((o - v.orientation + 0.5) % 1) - 0.5
  local dir = defines.riding.direction.straight
  if diff > 0.012 then dir = defines.riding.direction.right
  elseif diff < -0.012 then dir = defines.riding.direction.left end
  local speed = v.speed or 0
  local accel
  if reverse then
    accel = defines.riding.acceleration.reversing
    if dir == defines.riding.direction.right then dir = defines.riding.direction.left
    elseif dir == defines.riding.direction.left then dir = defines.riding.direction.right end
  else
    local want = (math.abs(diff) > 0.12) and math.min(turn_speed, speed_cap) or speed_cap
    if speed < want then accel = defines.riding.acceleration.accelerating
    elseif speed > want + slack then accel = defines.riding.acceleration.braking
    else accel = defines.riding.acceleration.nothing end
  end
  local ok = pcall(function() v.riding_state = {acceleration = accel, direction = dir} end)
  return ok
end

-- The point of the route a short way AHEAD ALONG THE ROUTE (not in a straight line, which would cut corners through
-- buildings). The lookahead grows with speed but stays small, so the car stays on the route the pathfinder cleared.
local function aim_point(v, r, cfg)
  local list = r.waypoints
  if not list then return r.goal, 0 end
  local p = v.position

  -- the closest route point near the current one (the car may have drifted or been pushed)
  local best_i, best_d = r.index, math.huge
  for i = math.max(1, r.index - 2), math.min(#list, r.index + 30) do
    local d = common.dist2(p, list[i])
    if d < best_d then best_i, best_d = i, d end
  end
  r.index = best_i
  -- once it is on a point, aim past it
  while list[r.index + 1] and dist(p, list[r.index]) < 2.5 do r.index = r.index + 1 end

  -- ec-vehicle-aim-distance: how far ahead along the route the car aims (grows with speed up to twice that)
  local min_look = cfg.aim_distance
  local look = math.max(min_look, math.min(min_look * 2, min_look + math.abs(v.speed or 0) * 25))
  local walked, i = dist(p, list[r.index]), r.index
  while list[i + 1] and walked < look do
    walked = walked + dist(list[i], list[i + 1])
    i = i + 1
  end

  -- how sharp is the route in the next ~15 tiles? (a sharp bend needs a slow car)
  local j1, j2 = math.min(#list, r.index + 6), math.min(#list, r.index + 14)
  local turn = 0
  if j1 > r.index and j2 > j1 then
    local a1 = math.atan2(list[j1].x - list[r.index].x, list[j1].y - list[r.index].y)
    local a2 = math.atan2(list[j2].x - list[j1].x, list[j2].y - list[j1].y)
    turn = math.abs((a2 - a1 + math.pi) % (2 * math.pi) - math.pi)
  end
  return list[i], turn
end

local function drive(data, r, target, stop, cfg)
  local c, v = data.entity, r.vehicle
  if not (v.valid and c.valid) then return M.dismount(data, M.FAIL_COOLDOWN) end
  if v.get_driver() == nil then return M.dismount(data, M.FAIL_COOLDOWN, "lost the seat of the " .. v.name) end

  local leave = math.max(cfg.dismount, stop + 5)

  -- a long drive: top the tank up from the carried fuel (the best one), or walk on when it ran dry
  local sup = M.supplier
  if sup and game.tick >= (r.fuel_check or 0) then
    r.fuel_check = game.tick + 180
    local left = dist(v.position, r.goal)
    if sup.low(v, left) and not sup.fill(data, v, left) and tank_empty(v) then
      return M.dismount(data, M.FAIL_COOLDOWN, "the " .. v.name .. " ran out of fuel and I have none: continuing on foot")
    end
  end

  -- the task has a new goal while driving: get a route for it, staying seated
  if dist(target, r.goal) > 10 then
    r.goal = {x = target.x, y = target.y}
    r.waypoints, r.index, r.found, r.failed, r.retry, r.simplify = nil, 1, nil, nil, nil, nil
    if dist(v.position, r.goal) > leave then
      if r.spider then
        r.waypoints = {r.goal}
        draw_route(data, r, cfg.show_route)
      elseif request_route(data, r) then
        r.phase = "routing"
      else
        return M.dismount(data, M.FAIL_COOLDOWN)
      end
    end
  end

  if r.phase == "routing" then
    -- waiting for a new route: stand still, but never brake to a stop on a rail (roll on instead)
    local accel = rails.on_rail(v) and defines.riding.acceleration.nothing or defines.riding.acceleration.braking
    pcall(function() v.riding_state = {acceleration = accel, direction = defines.riding.direction.straight} end)
    if r.simplify then
      simplify_step(data, r, cfg)
      return true
    end
    if r.found then
      r.phase, r.found = "driving", nil
      r.check_pos, r.check_tick, r.stuck = nil, nil, 0
      draw_route(data, r, cfg.show_route)
    elseif r.failed and thinner_margin(data, r, cfg) then
      r.failed = nil
      if not request_route(data, r) then r.failed = true end
    elseif r.failed or (not r.req and not r.retry) or game.tick - (r.req_tick or 0) > cfg.timeout then
      return M.dismount(data, M.FAIL_COOLDOWN, "no new route found for the " .. v.name .. ": continuing on foot")
    elseif r.retry then
      r.retry = nil
      request_route(data, r)
    end
    return true
  end

  -- arrived: stop (below the dismount speed, and NOT on a rail), then get out and walk the rest
  local list = r.waypoints
  local arrived = dist(v.position, r.goal) <= leave
  local route_end = not r.spider and list and r.index >= #list and dist(v.position, list[#list]) < M.WAYPOINT_REACHED + 3
  local roll_on -- true: the vehicle stands on a rail and has to roll off it before it may stop
  if arrived or route_end then
    local text
    if arrived then
      text = "got out near the goal (" .. math.floor(dist(v.position, r.goal)) .. " tiles to go)"
    else
      text = "reached the end of the route (" .. math.floor(dist(v.position, r.goal)) .. " tiles from the goal): continuing on foot"
    end
    if r.spider then
      M.dismount(data, M.SEARCH_COOLDOWN, text)
      return "base"
    end
    r.arrive_tick = r.arrive_tick or game.tick
    local waited = game.tick - r.arrive_tick
    local on_rail = rails.on_rail(v)
    local speed = math.abs(v.speed or 0)
    if not on_rail and (speed <= cfg.dismount_speed or waited > 600) then
      M.dismount(data, M.SEARCH_COOLDOWN, text)
      return "base"
    elseif on_rail and waited > 1800 then
      M.dismount(data, M.SEARCH_COOLDOWN, text .. " (could not roll off the rails)")
      return "base"
    elseif not on_rail then
      -- brake to a standstill; this is not "stuck"
      pcall(function() v.riding_state = {acceleration = defines.riding.acceleration.braking, direction = defines.riding.direction.straight} end)
      r.check_tick = nil
      data.status = string.format("Stopping the %s (%d km/h)", v.name, math.floor(speed * 216))
      return true
    end
    roll_on = true
    note(data, "the " .. v.name .. " is on a rail: rolling on before getting out", "rollon")
  else
    r.arrive_tick = nil
  end

  if r.spider then
    if game.tick >= (r.next_autopilot or 0) then
      r.next_autopilot = game.tick + 60
      pcall(function() v.autopilot_destination = r.goal end)
    end
  else
    -- stuck handling: 1st time reverse for a moment, 2nd time ask for a NEW route from here with more clearance,
    -- after that give up and walk
    r.check_tick = r.check_tick or game.tick
    if game.tick - r.check_tick >= 45 then
      local moved = r.check_pos and dist(v.position, r.check_pos) or 99
      r.check_pos, r.check_tick = {x = v.position.x, y = v.position.y}, game.tick
      if moved < 1.2 and game.tick >= (r.reverse_until or 0) then
        r.stuck = (r.stuck or 0) + 1
        if r.stuck == 1 then
          r.reverse_until = game.tick + 60
          note(data, "the " .. v.name .. " is stuck: backing up", "stuck1")
        else
          r.stuck = 0
          r.reroutes = (r.reroutes or 0) + 1
          if r.reroutes > 3 then
            return M.dismount(data, M.FAIL_COOLDOWN, "the " .. v.name .. " got stuck again and again: continuing on foot")
          end
          if not thinner_margin(data, r, cfg) then r.extra_clearance = (r.extra_clearance or 0) + 0.15 end
          r.waypoints, r.index, r.found, r.failed, r.retry, r.simplify = nil, 1, nil, nil, nil, nil
          if request_route(data, r) then
            r.phase = "routing"
            note(data, string.format("the %s is stuck: asking for a new route with more clearance (try %d)", v.name, r.reroutes), "stuck2")
            return true
          end
          return M.dismount(data, M.FAIL_COOLDOWN, "could not ask for a new route after getting stuck")
        end
      end
    end
    local aim, turn = aim_point(v, r, cfg)
    local reverse = game.tick < (r.reverse_until or 0)
    local pressure = 0
    if not reverse then
      -- steer around corners instead of hugging them; after a stuck re-route, use less margin (narrow gaps)
      local margin = cfg.steer_margin * margin_scale(r)
      local n
      aim, pressure, n = steering.adjust(v, c, aim, margin, r, cfg.debug, cfg.steer_size)
      if cfg.debug and margin > 0 then
        note(data, string.format("steering: %d obstacle(s) near, margin %.2f tiles, squeeze %d%%", n, margin, math.floor(pressure * 100)), "steer")
      end
    end
    local far = dist(v.position, r.goal)
    -- Speeds. Default: no limit of our own, so the vehicle goes as fast as IT can. With the max speed setting (an
    -- override, km/h) the limit is that value and the bend / turn / near-goal speeds scale with it
    -- (their defaults are for 0.2 tiles/tick).
    local override = cfg.max_speed > 0
    local f = override and cfg.max_speed / M.TOP_SPEED or 1
    r.top_seen = math.max(r.top_seen or 0, math.abs(v.speed or 0))
    local top = override and cfg.max_speed or math.huge
    local ref = override and cfg.max_speed or math.max(M.TOP_SPEED, r.top_seen)
    local bend, turn_speed = math.min(M.BEND_SPEED * f, ref), math.min(M.TURN_SPEED * f, ref)
    local cap = top
    if turn > 0.35 then cap = math.min(cap, bend) end
    if far < leave + 30 then cap = math.min(cap, M.NEAR_GOAL_SPEED * f) end
    -- squeezed between obstacles: slow down, the more the closer
    if pressure > 0 then cap = math.min(cap, ref - (ref - turn_speed) * pressure) end

    local hold
    if roll_on then
      cap = math.min(cap, 0.06) -- off the rails, slowly
      aim = route_end and r.goal or aim
    elseif cfg.rail_check and not reverse then
      -- rails ahead on the route? slow down; wait in front of them while a train is coming
      local g = rails.guard(v, r, rails.body_radius(v, cfg.steer_size), cfg.train_time)
      if g then
        if g.cap then cap = math.min(cap, g.cap) end
        hold = g.hold
        if g.why then note(data, g.why, "rails") end
      end
    end
    if hold then
      pcall(function() v.riding_state = {acceleration = defines.riding.acceleration.braking, direction = defines.riding.direction.straight} end)
      r.check_tick = nil -- standing still on purpose is not "stuck"
      data.status = "Waiting for a train to pass"
      return true
    end

    if cfg.debug then
      local shown = cap == math.huge and "no limit (vehicle's own top speed)" or string.format("%d km/h", math.floor(cap * 216))
      note(data, "speed limit: " .. shown, "speed")
    end
    if not steer(v, aim, cap, reverse, turn_speed, 0.05 * f) then
      return M.dismount(data, 36000, "the " .. v.name .. " cannot be steered by script: walking")
    end
  end

  if game.tick % 60 == 0 then
    data.status = string.format("Driving %s (%d tiles to go)", v.name, math.floor(dist(v.position, r.goal)))
  end
  return true
end

---------------------------------------------------------------------
-- Deciding to ride
---------------------------------------------------------------------

local function consider(data, target, stop, cfg)
  if not cfg.enabled then return end
  local c = data.entity
  if game.tick < (data.ride_cd or 0) then
    if data.ride_last and dist(c.position, target) >= cfg.min_distance then
      note(data, string.format("not trying a vehicle for %d more s (last: %s)", math.ceil((data.ride_cd - game.tick) / 60), data.ride_last), "cooldown")
    end
    return
  end
  if c.vehicle or c.driving then return end
  local far = dist(c.position, target)
  if far < cfg.min_distance then
    if far >= cfg.min_distance * 0.6 then
      note(data, string.format("goal is %d tiles away, driving starts at %d (setting)", math.floor(far), cfg.min_distance))
    end
    return
  end

  -- a very long trip is worth a longer walk to the vehicle: at least the setting, up to 10 % of the trip (max 150)
  local sup = M.supplier

  -- the fuel for a vehicle is on its way (a chest / the drills / by hand): wait until the tank has it
  local fc = data.fuel_chain
  if fc then
    if game.tick > fc.expires or not fc.vehicle.valid or not sup or not sup.low(fc.vehicle, far) then
      data.fuel_chain = nil
    else
      return
    end
  end

  local radius = math.max(cfg.search, math.min(150, far * 0.1))
  local v, why = find_vehicle(c, radius)
  if not v then
    -- none near: craft a car (scripts/vehicle_supply.lua)
    if sup and cfg.craft then
      local made, state, reason = sup.acquire(data, far)
      if made then
        v = made
        note(data, "put down a new " .. v.name .. " for the trip")
      elseif state == "busy" then
        data.ride_cd = game.tick + 120
        return
      elseif reason then
        why = why .. " - and " .. reason
      end
    end
    if not v then
      note(data, why .. " (goal " .. math.floor(far) .. " tiles away)")
      data.ride_cd = game.tick + M.SEARCH_COOLDOWN
      return
    end
  end

  -- enough fuel for the trip? Carried fuel is put in when boarding; otherwise a refuelling chain starts
  if sup then
    local state, reason = sup.fuel_state(data, v, far)
    if state == "chain" then
      data.fuel_chain = {vehicle = v, expires = game.tick + 3600}
      data.ride_cd = nil
      return
    elseif state == "none" then
      note(data, "the " .. v.name .. " needs fuel: " .. (reason or "none found"))
      data.ride_cd = game.tick + M.SEARCH_COOLDOWN * 2
      return
    end
  end
  note(data, string.format("found %s %d tiles away, goal %d tiles away: checking for a route", v.name, math.floor(dist(c.position, v.position)), math.floor(far)))

  local r = {
    vehicle = v, goal = {x = target.x, y = target.y}, start_tick = game.tick, last_walk = game.tick,
    spider = (v.type == "spider-vehicle"), lines = {}, index = 1,
  }
  data.ride = r
  if r.spider then -- legs: no obstacles to trace a route around
    r.phase, r.waypoints = "boarding", {r.goal}
  elseif request_route(data, r) then
    r.phase = "checking"
  else
    data.ride, data.ride_cd = nil, game.tick + M.FAIL_COOLDOWN
    data.ride_last = "the route request was refused"
  end
end

-- Returns true when this tick was spent on the ride, "base" to walk normally, nil/false otherwise.
local function step(data, r, target, stop, cfg)
  local c = data.entity
  local v = r.vehicle
  if not (v and v.valid) then return M.dismount(data, M.FAIL_COOLDOWN) end

  if r.phase == "checking" then
    c.walking_state = {walking = false}
    if r.simplify then
      simplify_step(data, r, cfg)
      return true
    end
    if r.found then
      r.phase, r.found = "boarding", nil
      note(data, string.format("route found (%d points): going to the %s", #(r.waypoints or {}), v.name))
    elseif r.failed and thinner_margin(data, r, cfg) then
      r.failed = nil
      if not request_route(data, r) then r.failed = true end
    elseif r.failed or (not r.req and not r.retry) then
      data.ride, data.ride_cd = nil, game.tick + M.FAIL_COOLDOWN
      data.status = "No drivable route: walking"
      note(data, string.format("the game found no drivable route for the %s: blocked by water / cliffs / trees / buildings? Try a lower body scale or a bigger goal tolerance in the mod settings. Walking", v.name))
      return "base"
    elseif game.tick - r.start_tick > cfg.timeout then
      data.ride, data.ride_cd = nil, game.tick + M.FAIL_COOLDOWN
      data.status = "Route search timed out: walking"
      note(data, string.format("the route search took longer than %d s (long trip?): raise the route timeout in the mod settings. Walking", math.floor(cfg.timeout / 60)))
      return "base"
    elseif r.retry then
      r.retry = nil
      request_route(data, r)
    end
    return true
  end

  if r.phase == "boarding" then
    local ok, why = usable(v, true)
    if not ok then return M.dismount(data, M.FAIL_COOLDOWN, "the " .. v.name .. " is no longer usable (" .. why .. ")") end
    if game.tick - r.start_tick > M.BOARD_TIMEOUT then
      return M.dismount(data, M.FAIL_COOLDOWN, "could not walk up to the " .. v.name .. " in time (something in the way?)")
    end
    data.status = "Going to the " .. v.name
    if base_walk(data, v.position, M.BOARD_REACH) then
      local sup = M.supplier
      if sup and sup.low(v, dist(v.position, r.goal)) then sup.fill(data, v, dist(v.position, r.goal)) end
      if tank_empty(v) then
        return M.dismount(data, M.FAIL_COOLDOWN, "the " .. v.name .. " has no fuel and I have none to put in: walking")
      end
      pcall(v.set_driver, c)
      if v.get_driver() == nil then return M.dismount(data, M.FAIL_COOLDOWN, "could not get into the " .. v.name) end
      c.walking_state = {walking = false}
      data.ride_last = nil
      note(data, "driving the " .. v.name .. " to the goal (" .. math.floor(dist(v.position, r.goal)) .. " tiles)")
      r.phase, r.start_tick = "driving", game.tick
      draw_route(data, r, cfg.show_route)
    end
    return true
  end

  return drive(data, r, target, stop, cfg)
end

---------------------------------------------------------------------
-- The walker
---------------------------------------------------------------------

-- Wraps the on-foot walker (pathing.walk): same contract (true once within `stop` tiles of `target`).
function M.wrap(base)
  base_walk = base
  return function(data, target, stop)
    local c = data.entity
    if not (c and c.valid) then return base(data, target, stop) end
    local cfg = config(data)

    local r = data.ride
    if not r then
      consider(data, target, stop, cfg)
      r = data.ride
    end
    if r then
      r.last_walk = game.tick
      local result = step(data, r, target, stop, cfg)
      if result == true then return false end -- this tick went into the ride; anything else: walk
    end
    return base(data, target, stop)
  end
end

return M
