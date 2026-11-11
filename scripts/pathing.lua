-- Walking with collision.
--
-- The companion has the player's collision mask (buildings, trees, cliffs, water stop it). common.walk_towards
-- calls M.walk, which is PATH-FIRST (0.19.1; before, it walked in a straight line until it noticed a problem, and
-- a character that slides along a wall still "makes progress", so it kept pushing against buildings):
--
--   * a short hop (<= SHORT_HOP tiles) whose straight corridor is verified free (with a generous allowance for
--     the 8-direction zigzag) is walked directly;
--   * EVERYTHING ELSE asks the game for a route first (surface.request_path with the companion's own bounding
--     box and collision mask; the answer arrives in on_script_path_request_finished -> M.on_path_finished) and
--     STANDS STILL until it has one. It never walks a long straight line "to see what happens";
--   * the route is densified (a point every SPACING tiles) so the 8-direction walking cannot drift away from it
--     and clip the corners the pathfinder hugs;
--   * when the target moves (following the player) the old route keeps being followed while a new one is requested;
--   * stuck detection measures PROGRESS TOWARDS THE AIM, not distance moved: sliding along a wall is stuck;
--   * stuck -> new route with more clearance; stuck again -> unwedge; again -> step next to the target;
--   * no route twice (target on an island, behind water...) -> it does NOT fly: it steps to the nearest free spot
--     next to the target (a teleport), so a task never hangs for ever.
--
-- LONG TRIPS (0.19.6): a trip longer than HOP_MIN_TRIP tiles is WALKED IN HOPS of HOP_LENGTH tiles (the idea of
-- hierarchical pathfinding: one long search is the expensive thing, many short ones are cheap):
--   * the first hop is searched like any route; while the companion walks it, the NEXT hop is already being
--     calculated from the end of the current route (low priority, so it never takes the pathfinder's budget);
--   * when the current hop is walked the next one is swapped in, and the one after it starts calculating;
--   * the intermediate goal of a hop is a free spot on the straight line to the target; if the game finds no route to
--     it, other angles / a shorter hop are tried, and only then one long search to the target;
--   * the game's path cache is used (repeated trips between the same places are cheap); a stuck companion asks again
--     with the cache off.
-- NO ROUTE (0.19.8): when the game finds none (twice: the second time with the least clearance and a wider radius) it
-- does NOT teleport: it walks straight at the goal as far as the terrain allows, and calls that arrived ("blind"
-- walking). Teleport / journey as a last resort exist only when the setting ec-teleport-fallback is on.
-- (The optional "journey" - ec-journey-enabled, off by default - is a fast travel: it waits for the travel time and
--  teleports. It is also what the "no way to the target" fallback uses for a goal more than TELEPORT_MAX tiles away.)
--
-- State: data.nav = {goal, request, request_target, waypoints, index, next (the hop calculated ahead), next_request,
--                    chk, fails, reroutes, tight, ...}

local common = require("scripts.common")
local vehicles = require("scripts.vehicles")
local debug_log = require("scripts.debug")
local steering = require("scripts.steering") -- only its obstacle finder (boxes colliding with a given entity)

local M = {}

local CHECK_TICKS      = 30    -- progress is judged over this many ticks (it walks ~4.5 tiles in that time)
local MIN_PROGRESS     = 0.5   -- tiles closer to the aim it must get in CHECK_TICKS, else it is stuck (sliding along a wall is not progress)
local MIN_MOVE         = 0.8   -- ... and tiles it must move at all (for an aim that keeps moving)
local REQUEST_COOLDOWN = 45    -- ticks between two path requests
local WAYPOINT_REACHED = 0.4   -- tiles
local PASSED_WITHIN    = 1.2   -- a waypoint it has already walked past (and is this close to) counts as reached
local SPACING          = 1.0   -- the route is densified: a point at least every SPACING tiles
local MAX_FAILS        = 2     -- "no path" answers before it gives up and steps to the target (a search that cannot succeed is EXPENSIVE: it floods the whole region)
local UNREACH_TICKS    = 1800  -- a goal that had no route is not searched for again for this long
local FREE_SPOT_RADIUS = 10
local SHORT_HOP        = 6     -- tiles (beyond `stop`) it may walk without asking for a route, if the corridor is free
local LINE_CHECK_TICKS = 15    -- how often obstacles are looked for
local NO_PATH_PAUSE    = 90    -- ticks it may just walk (stuck check on) after the game said "no path" to a short hop
local PATH_MARGIN      = 0.35  -- tiles added around the companion's box for the pathfinder
local TIGHT_MARGIN     = 0.05  -- after a "no path" answer, so narrow gaps stay usable before it gives up
local DRIFT_BASE       = 0.4   -- clearance of the straight corridor of a short hop ...
local DRIFT_PER_TILE   = 0.2   -- ... plus this per tile (8-direction walking drifts ~12 degrees off the line)
local MARGIN_PER_RETRY = 0.15
local MAX_MARGIN       = 0.75
local UNWEDGE_AFTER    = 3     -- stuck this many times in a row: move out of whatever it is wedged in
local GIVE_UP_AFTER    = 5     -- ... and after this many: step next to the target instead
local GOOD_WAYPOINTS   = 6     -- waypoints reached in a row that forget earlier "stuck"s
local GOAL_SHIFT       = 3     -- the target moved this far from where the route leads: ask for a new route
local NEW_TRIP_DIST    = 12    -- ... this far: it is another destination, the old route is useless
local REPATH_TICKS     = 60    -- min ticks between two routes for a moving target
local HOP_LENGTH        = 60    -- tiles per hop of a long trip (default of the setting ec-hop-length)
local HOP_MIN_TRIP      = 90    -- a trip shorter than this is one search (default of ec-hop-min-trip)
local HOP_RADIUS        = 4     -- an intermediate hop ends within this many tiles of its goal
local HOP_MAX_BIAS      = 6     -- other hop goals tried (angles, shorter) before one long search to the target (a 1000-tile one is costly)
local ARRIVE_DISTANCE  = 24    -- a journey ends this far from the goal (plus `stop`)
local TELEPORT_MAX     = 30    -- instant moves ("no way to the target") never go farther than this
local STEER_TOL        = math.rad(8) -- the aim is close (<= SPACING), stick to it

local function nav_of(data)
  data.nav = data.nav or {}
  return data.nav
end

local function reset_path(nav)
  nav.waypoints, nav.index, nav.request, nav.request_goal = nil, nil, nil, nil
  nav.chk, nav.line_tick, nav.line_free, nav.wp_check = nil, nil, nil, nil
  nav.no_path_until, nav.good = nil, 0
  nav.tight = false
  nav.next, nav.next_request, nav.next_goal, nav.next_final, nav.next_start = nil, nil, nil, nil, nil
  nav.next_bias, nav.next_retry, nav.hop_final, nav.hop_bias = 0, nil, nil, 0
  nav.blind, nav.bchk, nav.accept, nav.next_accept = nil, nil, nil, nil
end

function M.reset(data)
  data.nav = nil
end

local function xy(p) return p.x or p[1], p.y or p[2] end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- half of the narrow side of the companion's collision box (prototype data, safe to cache)
local half_w
local function half_width()
  if not half_w then
    local box = prototypes.entity[common.ENTITY_NAME].collision_box
    local lx, ly = xy(box.left_top or box[1])
    local rx, ry = xy(box.right_bottom or box[2])
    half_w = math.min(rx - lx, ry - ly) / 2
  end
  return half_w
end

-- Does the segment (ax,ay)-(bx,by) cross the box? (Liang-Barsky clipping)
local function seg_box(l, t, r, b, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local t0, t1 = 0, 1
  local function clip(pp, q)
    if pp == 0 then return q >= 0 end
    local u = q / pp
    if pp < 0 then
      if u > t1 then return false end
      if u > t0 then t0 = u end
    else
      if u < t0 then return false end
      if u < t1 then t1 = u end
    end
    return true
  end
  return clip(-dx, ax - l) and clip(dx, r - ax) and clip(-dy, ay - t) and clip(dy, b - ay) and t0 <= t1
end

-- Is something that stops the companion on the straight line p -> target (ending `stop * 0.8` tiles before it)?
-- `extra` widens the corridor on both sides.
local function line_blocked(c, p, target, stop, extra)
  local dx, dy = target.x - p.x, target.y - p.y
  local len = math.sqrt(dx * dx + dy * dy)
  local reach = len - stop * 0.8
  if reach <= 0.3 then return false end
  local ex, ey = p.x + dx / len * reach, p.y + dy / len * reach
  local pad = 1 + (extra or 0)
  local area = {
    {math.min(p.x, ex) - pad, math.min(p.y, ey) - pad},
    {math.max(p.x, ex) + pad, math.max(p.y, ey) + pad},
  }
  local ok, boxes = pcall(steering.obstacles, c, c, area)
  if not ok or not boxes then return true end -- cannot tell: do not trust the straight line
  local w = math.max(0.05, half_width() - 0.03 + (extra or 0))
  for _, b in ipairs(boxes) do
    if seg_box(b.l - w, b.t - w, b.r + w, b.b + w, p.x, p.y, ex, ey) then return true end
  end
  return false
end

local function note(data, text)
  data.nav_note, data.nav_note_tick = text, game.tick -- shown in the status text (control.lua)
end

local function player_of(data)
  for index, d in pairs(storage.companions or {}) do
    if d == data then return game.get_player(index) end
  end
  return nil
end

local function debug_on(data)
  local pl = player_of(data)
  return pl and debug_log.enabled(pl) and pl or nil
end

local function current_margin(nav)
  if nav.tight then return TIGHT_MARGIN end
  return math.min(MAX_MARGIN, PATH_MARGIN + (nav.reroutes or 0) * MARGIN_PER_RETRY)
end

-- Settings of the walking (per player; read once a second, not every tick)
local function nav_cfg(data)
  local cache = data.jcfg
  if cache and game.tick - cache.tick < 60 and cache.hop_length then return cache end
  local pl = player_of(data)
  local s = pl and settings.get_player_settings(pl)
  local function get(name, default)
    local v = s and s[name]
    if v == nil then return default end
    return v.value
  end
  cache = {
    tick = game.tick,
    hop_length = get("ec-hop-length", HOP_LENGTH),
    hop_min = get("ec-hop-min-trip", HOP_MIN_TRIP),
    prefetch = get("ec-hop-prefetch", true),
    enabled = get("ec-journey-enabled", false),
    teleport = get("ec-teleport-fallback", false),
    distance = get("ec-journey-distance", 100),
    speed = get("ec-journey-speed", 100) / 100,
  }
  data.jcfg = cache
  return cache
end

-- The goal of the next hop from `from`: a free spot HOP_LENGTH tiles along the line to the target (bias 1, 2, 3...:
-- other angles, a shorter hop). Returns goal, is_final (the target itself: short enough, or nothing else worked).
local function hop_goal(c, from, target, stop, bias, cfg)
  local dx, dy = target.x - from.x, target.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  local limit = math.max(cfg.hop_min, cfg.hop_length + 10) -- (never a "hop" as long as the trip)
  if len <= limit or bias >= HOP_MAX_BIAS then return target, true end
  local length = cfg.hop_length * (bias >= 2 and 0.7 or 1)
  local angle = math.atan2(dy, dx)
  if bias > 0 then angle = angle + ((bias % 2 == 1) and 1 or -1) * math.rad(25) * math.ceil(bias / 2) end
  local want = {x = from.x + math.cos(angle) * length, y = from.y + math.sin(angle) * length}
  local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, want, math.max(16, length * 0.2), 1)
  if spot then return spot, false end
  return target, true
end

-- One request to the game's pathfinder. low: low priority (the game spends its budget on others first).
local function send_request(c, nav, start, goal, radius, low)
  local proto = prototypes.entity[common.ENTITY_NAME]
  local lx, ly = xy(proto.collision_box.left_top or proto.collision_box[1])
  local rx, ry = xy(proto.collision_box.right_bottom or proto.collision_box[2])
  local m = current_margin(nav)
  local box = {{lx - m, ly - m}, {rx + m, ry + m}}
  local fresh = (nav.reroutes or 0) > 0 or nav.tight -- stuck before: do not take a cached route
  local ok, id = pcall(function()
    return c.surface.request_path{
      bounding_box = box,
      collision_mask = proto.collision_mask,
      start = start,
      goal = goal,
      force = c.force,
      radius = radius,
      can_open_gates = true,
      path_resolution_modifier = 0,
      pathfind_flags = {cache = not fresh, low_priority = low},
    }
  end)
  if ok and id then return id end
  return nil
end

-- The route the companion walks now (from where it stands): the first hop of the trip, or all of it if short.
local function request_path(data, nav, target, stop)
  local c = data.entity
  nav.next, nav.next_request = nil, nil -- a hop calculated ahead belonged to the old route
  local goal, final = hop_goal(c, c.position, target, stop, nav.hop_bias or 0, nav_cfg(data))
  -- the second try (after "no route") also accepts a route that ends farther from the goal: a big building around
  -- the goal keeps the route from getting within 0.8 * stop of its centre
  local radius = final and math.max(1, stop * ((nav.fails or 0) >= 1 and 1.5 or 0.8)) or HOP_RADIUS
  local id = send_request(c, nav, c.position, goal, radius, false)
  if id then
    nav.request, nav.request_tick = id, game.tick
    nav.request_target, nav.request_final = {x = target.x, y = target.y}, final
    nav.request_accept = final and (radius + 1) or nil
  else
    nav.fails = (nav.fails or 0) + 1
  end
  nav.retry_at = game.tick + REQUEST_COOLDOWN
end

-- While the current hop is walked: calculate the NEXT one, starting at the end of the current route.
local function prefetch(data, nav, target, stop)
  local c = data.entity
  local last = nav.waypoints[#nav.waypoints]
  local goal, final = hop_goal(c, last, target, stop, nav.next_bias or 0, nav_cfg(data))
  local radius = final and math.max(1, stop * 0.8) or HOP_RADIUS
  local id = send_request(c, nav, last, goal, radius, true)
  if id then
    nav.next_request, nav.next_tick = id, game.tick
    nav.next_goal, nav.next_final, nav.next_start = goal, final, {x = last.x, y = last.y}
    nav.next_accept = final and (radius + 1) or nil
  else
    nav.next_bias = (nav.next_bias or 0) + 1
    nav.next_retry = game.tick + REQUEST_COOLDOWN
  end
end

-- Goals the game found no route to: remembered, so a task that keeps asking for the same goal does not start the same
-- hopeless (and costly) search again and again.
local function unreachable(data, target)
  local list = data.unreach
  if not list then return false end
  for i = #list, 1, -1 do
    local u = list[i]
    if game.tick > u.t then
      table.remove(list, i)
    elseif common.dist2(u, target) < 9 then
      return true
    end
  end
  return false
end

local function mark_unreachable(data, target)
  data.unreach = data.unreach or {}
  local list = data.unreach
  list[#list + 1] = {x = target.x, y = target.y, t = game.tick + UNREACH_TICKS}
  while #list > 8 do table.remove(list, 1) end
end

---------------------------------------------------------------------
-- Journeys (long trips)
---------------------------------------------------------------------

-- Where a journey to `target` ends: a free spot ~ARRIVE_DISTANCE + stop tiles from it, on the side it comes from.
local function staging_spot(c, target, stop)
  local p = c.position
  local dx, dy = p.x - target.x, p.y - target.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return nil end
  local back = stop + ARRIVE_DISTANCE
  local aim = {x = target.x + dx / len * back, y = target.y + dy / len * back}
  local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, aim, 16, 0.5)
  if spot and dist(spot, p) > 15 then return spot end
  return nil
end

-- Starts a journey to `spot` (the goal it is for is `goal`). The companion stays where it is until the time is up.
local function begin_journey(data, spot, goal)
  local c = data.entity
  local cfg = nav_cfg(data)
  local speed = (common.try_get(c, "character_running_speed") or 0.15) * cfg.speed
  local d = dist(c.position, spot)
  local ticks = math.max(60, math.ceil(d / math.max(0.05, speed)))
  data.journey = {
    goal = {x = goal.x, y = goal.y}, spot = {x = spot.x, y = spot.y},
    arrive = game.tick + ticks, last = game.tick, total = ticks,
  }
  data.nav = nil
  c.walking_state = {walking = false}
  note(data, string.format("long trip: travelling %d tiles (%d s)", math.floor(d), math.ceil(ticks / 60)))
end

-- One tick of a journey. Returns true while it is under way.
local function journey_step(data, j)
  local c = data.entity
  j.last = game.tick
  if game.tick >= j.arrive then
    data.journey = nil
    data.nav = nil
    if not c.teleport(j.spot) then
      local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, j.spot, 10, 0.5)
      if spot then c.teleport(spot) end
    end
    note(data, "arrived at the end of the long trip")
    return false
  end
  c.walking_state = {walking = false}
  local left = math.ceil((j.arrive - game.tick) / 60)
  data.status = "Travelling (" .. left .. " s left)"
  if game.tick % 60 == 0 then
    pcall(rendering.draw_text, {
      text = "Travelling... " .. left .. " s", surface = c.surface, target = {entity = c, offset = {0, -2.2}},
      color = {r = 1, g = 1, b = 1}, scale = 0.9, alignment = "center", time_to_live = 70,
      forces = {c.force},
    })
  end
  return true
end

-- Last resort when there is no way to the target: the nearest free spot next to it.
local function step_to_target(data, nav, target)
  local c = data.entity
  local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, target, FREE_SPOT_RADIUS, 0.5)
  if spot then
    if dist(c.position, spot) > TELEPORT_MAX and nav_cfg(data).enabled then
      begin_journey(data, spot, target) -- not an instant jump across the map: it takes the time of the trip
    else
      c.teleport(spot)
    end
  end
  reset_path(nav)
  nav.fails, nav.reroutes = 0, 0
  nav.goal = {x = target.x, y = target.y}
  mark_unreachable(data, target)
  note(data, "no way to the target: next to it")
end

-- No route to the target (tried twice) or stuck for good. Default: NO teleport - walk straight at it as far as the
-- terrain allows (blind_step) and call that arrived. With ec-teleport-fallback: the old "next to the target" jump.
local function give_up(data, nav, target)
  if nav_cfg(data).teleport then
    step_to_target(data, nav, target)
    return
  end
  reset_path(nav)
  nav.fails, nav.reroutes = 0, 0
  nav.goal = {x = target.x, y = target.y}
  nav.blind = true
  mark_unreachable(data, target)
  note(data, "no route to the target: going as close as possible")
end

-- Straight at the goal; when it cannot get any closer (30 ticks without moving) that is as near as it gets: arrived.
local function blind_step(data, nav, target, p)
  local c = data.entity
  local tick = game.tick
  local chk = nav.bchk
  local d = dist(p, target)
  if not chk then
    nav.bchk = {tick = tick, pos = {x = p.x, y = p.y}, d = d}
  elseif tick - chk.tick >= CHECK_TICKS then
    -- not moving, or sliding along something without getting closer: that is as near as it gets
    if dist(p, chk.pos) < MIN_MOVE or chk.d - d < MIN_PROGRESS then
      c.walking_state = {walking = false}
      data.nav = nil
      return true
    end
    nav.bchk = {tick = tick, pos = {x = p.x, y = p.y}, d = d}
  end
  c.walking_state = {walking = true, direction = common.steer(data, p, target, STEER_TOL)}
  return false
end

-- A point every <= SPACING tiles along the route, so 8-direction walking cannot drift away from it.
local function densify(path, start)
  local out, prev = {}, start
  for i = 2, #path do -- [1] is where it stands
    local wp = path[i].position or path[i]
    local dx, dy = wp.x - prev.x, wp.y - prev.y
    local n = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / SPACING))
    for k = 1, n do
      out[#out + 1] = {x = prev.x + dx * k / n, y = prev.y + dy * k / n}
    end
    prev = {x = wp.x, y = wp.y}
  end
  return out
end

-- It is stuck (no progress / the route is blocked): count it, ask for a new route with more clearance, unwedge or
-- give up when it keeps happening. Returns true when it stepped to the target (the caller stops for this tick).
local function reroute(data, nav, target, stop, p, why)
  local c = data.entity
  nav.reroutes = (nav.reroutes or 0) + 1
  nav.good = 0
  if nav.reroutes >= GIVE_UP_AFTER then
    give_up(data, nav, target)
    return true
  end
  if nav.reroutes >= UNWEDGE_AFTER and nav_cfg(data).teleport then
    -- maybe it is stuck INSIDE something (a building revived next to / on it): move to the nearest free spot
    local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, p, 4, 0.1)
    if spot and common.dist2(spot, p) > 0.01 then
      c.teleport(spot)
      note(data, "was wedged: moved to a free spot")
    end
  end
  note(data, why .. ": new route (try " .. nav.reroutes .. ")")
  nav.waypoints, nav.index, nav.chk, nav.wp_check = nil, nil, nil, nil
  nav.tight = false
  nav.request = nil
  local pl = debug_on(data)
  if pl then
    debug_log.mark(pl, c.surface, p, {r = 1, g = 0.3, b = 0.1},
      why .. " (clearance +" .. string.format("%.2f", current_margin(nav)) .. ")", 300, 0.3)
  end
  request_path(data, nav, target, stop)
  return false
end

-- Walks towards `target`; returns true once within `stop` tiles.
function M.walk(data, target, stop)
  local c = data.entity
  local p = c.position
  if common.dist2(p, target) <= stop * stop then
    c.walking_state = {walking = false}
    data.nav = nil
    return true
  end
  local tick = game.tick
  local nav = nav_of(data)

  -- a journey is under way: wait for it (another goal or a long silence cancels it)
  local j = data.journey
  if j then
    if common.dist2(j.goal, target) > 400 or tick - j.last > 180 then
      data.journey = nil
    else
      journey_step(data, j)
      return false
    end
  end

  -- this goal had no route a moment ago: no new search
  if unreachable(data, target) then
    local cfg = nav_cfg(data)
    if cfg.teleport then
      -- (opt-in) stand at the nearest free spot next to it and call it arrived
      if common.dist2(p, target) > (stop + FREE_SPOT_RADIUS + 2) ^ 2 then
        local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, target, FREE_SPOT_RADIUS, 0.5)
        if spot then
          if cfg.enabled and dist(p, spot) > TELEPORT_MAX then
            begin_journey(data, spot, target)
            return false
          end
          c.teleport(spot)
        end
      end
      c.walking_state = {walking = false}
      data.nav = nil
      return true
    elseif math.sqrt(common.dist2(p, target)) - stop <= cfg.hop_min then
      nav.blind = true -- close enough to just walk at it (a far one is walked in hops, as always)
    end
  end
  if nav.blind then return blind_step(data, nav, target, p) end

  -- a long trip: no route search over hundreds of tiles, no walking: travel time passes (see the header)
  local jcfg = nav_cfg(data)
  if jcfg.enabled and not c.vehicle and tick >= (data.journey_cd or 0)
      and math.sqrt(common.dist2(p, target)) - stop >= jcfg.distance then
    local spot = staging_spot(c, target, stop)
    if spot then
      begin_journey(data, spot, target)
      return false
    end
    data.journey_cd = tick + 600 -- no free spot there: walk it, and do not look again for a while
  end

  -- which destination does the route lead to?
  if not nav.goal then
    reset_path(nav)
    nav.goal, nav.fails, nav.reroutes = {x = target.x, y = target.y}, 0, 0
  else
    local shift2 = common.dist2(nav.goal, target)
    if shift2 > NEW_TRIP_DIST * NEW_TRIP_DIST then -- another destination altogether
      reset_path(nav)
      nav.goal, nav.fails, nav.reroutes = {x = target.x, y = target.y}, 0, 0
    elseif shift2 > GOAL_SHIFT * GOAL_SHIFT then -- a moving target (the player): new route, old one still followed
      if not nav.waypoints then
        nav.goal = {x = target.x, y = target.y}
      elseif not nav.request and tick >= (nav.repath_at or 0) then
        nav.repath_at = tick + REPATH_TICKS
        request_path(data, nav, target, stop)
      end
    end
  end

  if nav.request and tick - (nav.request_tick or 0) > 600 then nav.request = nil end -- answer lost
  if (nav.fails or 0) >= MAX_FAILS then
    give_up(data, nav, target)
    return false
  end

  -- 1. no route yet: walk a short, verified-free hop directly; for anything else ask for a route and WAIT
  if not nav.waypoints then
    local remaining = math.sqrt(common.dist2(p, target)) - stop
    local direct = false
    if tick < (nav.no_path_until or 0) and remaining <= SHORT_HOP + 4 then
      direct = true -- the game found no route for a short hop: just try (the stuck check guards)
    elseif remaining <= SHORT_HOP then
      if not nav.line_tick or tick - nav.line_tick >= LINE_CHECK_TICKS then
        nav.line_tick = tick
        nav.line_free = not line_blocked(c, p, target, stop, DRIFT_BASE + math.max(0, remaining) * DRIFT_PER_TILE)
      end
      direct = nav.line_free
    end
    if not direct then
      if not nav.request and tick >= (nav.retry_at or 0) then
        request_path(data, nav, target, stop)
      end
      c.walking_state = {walking = false} -- wait for the route instead of walking into things
      nav.chk = nil -- standing still on purpose is not "stuck"
      return false
    end
  end

  -- 2. the aim: the next point of the route, else the target itself (short hop)
  local aim = target
  if nav.waypoints then
    if nav.next_request and tick - (nav.next_tick or 0) > 600 then nav.next_request = nil end -- answer lost
    local wp
    for _ = 1, 2 do -- (the second round: after switching to the hop that was calculated meanwhile)
      wp = nav.waypoints[nav.index]
      while wp do
        local d2 = common.dist2(p, wp)
        local reached = d2 < WAYPOINT_REACHED * WAYPOINT_REACHED
        if not reached and d2 < PASSED_WITHIN * PASSED_WITHIN then
          local nxt = nav.waypoints[nav.index + 1]
          if nxt and (wp.x - p.x) * (nxt.x - wp.x) + (wp.y - p.y) * (nxt.y - wp.y) < 0 then reached = true end
        end
        if not reached then break end
        nav.index = nav.index + 1
        nav.good = (nav.good or 0) + 1
        if nav.good >= GOOD_WAYPOINTS then nav.reroutes, nav.good = 0, 0 end
        wp = nav.waypoints[nav.index]
      end
      if wp or not nav.next then break end
      -- this hop is walked: the next one was calculated while walking it
      nav.waypoints, nav.index = nav.next.points, 1
      nav.hop_final, nav.accept = nav.next.final, nav.next.accept
      nav.next, nav.chk, nav.wp_check = nil, nil, nil
      nav.next_bias, nav.next_retry = 0, nil
    end
    if wp then
      aim = wp
      -- start calculating the next hop (low priority) as soon as there is a hop that is not the last
      if nav_cfg(data).prefetch and not nav.hop_final and not nav.next and not nav.next_request
          and (nav.next_bias or 0) <= HOP_MAX_BIAS and tick >= (nav.next_retry or 0) then
        prefetch(data, nav, target, stop)
      end
    elseif nav.next_request then
      -- walked the whole hop and the next one is not ready yet: wait for it
      c.walking_state = {walking = false}
      nav.chk = nil
      return false
    elseif nav.hop_final and nav.accept and common.dist2(p, target) <= nav.accept ^ 2 then
      -- the route to the goal itself is walked: as close as the game's route gets (a big building around the goal)
      c.walking_state = {walking = false}
      data.nav = nil
      return true
    else -- end of the route and nothing ready (the target moved?) -> ask again from here
      nav.waypoints, nav.index, nav.chk = nil, nil, nil
      nav.goal = {x = target.x, y = target.y}
      c.walking_state = {walking = false}
      return false
    end
  end

  -- 3. stuck? progress TOWARDS THE AIM counts, not distance moved (a wall slides it along without getting closer)
  local d_aim = dist(p, aim)
  local idx = nav.index or 0
  local chk = nav.chk
  local stuck, why = false, "stuck"
  if not chk or chk.index ~= idx or tick - chk.tick > 6 * CHECK_TICKS then
    nav.chk = {tick = tick, pos = {x = p.x, y = p.y}, aim = {x = aim.x, y = aim.y}, d = d_aim, index = idx}
  elseif tick - chk.tick >= CHECK_TICKS then
    local aim_static = dist(aim, chk.aim) < 1
    if dist(p, chk.pos) < MIN_MOVE or (aim_static and chk.d - d_aim < MIN_PROGRESS) then stuck = true end
    nav.chk = {tick = tick, pos = {x = p.x, y = p.y}, aim = {x = aim.x, y = aim.y}, d = d_aim, index = idx}
  end

  -- a building / ghost revived on the way to the next route point?
  if not stuck and nav.waypoints and not nav.request
      and (not nav.wp_check or tick - nav.wp_check >= LINE_CHECK_TICKS) then
    nav.wp_check = tick
    if line_blocked(c, p, aim, 0) then stuck, why = true, "route blocked" end
  end

  if stuck then
    if nav.request then
      nav.chk = nil -- a new route is already on its way
    elseif tick >= (nav.retry_at or 0) then
      if not nav.waypoints and tick < (nav.no_path_until or 0) then
        nav.no_path_until = nil -- the short hop did not work: back to asking for routes
      end
      if reroute(data, nav, target, stop, p, why) then return false end
      c.walking_state = {walking = false}
      return false
    end
  end

  c.walking_state = {walking = true, direction = common.steer(data, p, aim, STEER_TOL)}
  return false
end

local function draw_route(pindex, data, from, list)
  local pl = game.get_player(pindex)
  if not (pl and debug_log.enabled(pl)) then return end
  for _, wp in ipairs(list) do
    rendering.draw_line{color = {r = 0.2, g = 1, b = 0.3}, width = 2, from = from, to = wp,
      surface = data.entity.surface, players = {pl}, time_to_live = 600}
    from = wp
  end
end

-- on_script_path_request_finished
function M.on_path_finished(e)
  if vehicles.on_path_finished(e) then return end -- a route requested for a vehicle (scripts/vehicles.lua)
  for pindex, data in pairs(storage.companions or {}) do
    local nav = data.nav
    if nav and nav.request == e.id then
      -- the route to walk now
      nav.request = nil
      if e.path and #e.path > 0 and data.entity and data.entity.valid then
        local list = densify(e.path, data.entity.position)
        if #list == 0 then list = {{x = e.path[#e.path].position.x, y = e.path[#e.path].position.y}} end
        nav.waypoints, nav.index, nav.fails = list, 1, 0
        nav.goal = nav.request_target or nav.goal
        nav.hop_final, nav.hop_bias, nav.accept = nav.request_final, 0, nav.request_accept
        nav.next, nav.next_request, nav.next_bias, nav.next_retry = nil, nil, 0, nil
        nav.chk, nav.no_path_until, nav.wp_check = nil, nil, nil
        draw_route(pindex, data, data.entity.position, list)
      elseif e.try_again_later then
        nav.retry_at = game.tick + REQUEST_COOLDOWN
      elseif not nav.request_final then
        -- no route to this hop's goal (a lake, an island): another angle / a shorter hop, then one long search
        nav.hop_bias = (nav.hop_bias or 0) + 1
        nav.retry_at = game.tick + 15
      else
        nav.fails = (nav.fails or 0) + 1
        nav.tight = true -- next time with little clearance: narrow gaps stay usable
        nav.retry_at = game.tick + 15
        -- a short hop whose corridor looked blocked may still work (target right next to an obstacle)
        nav.no_path_until = game.tick + NO_PATH_PAUSE
      end
      return
    elseif nav and nav.next_request == e.id then
      -- the hop AFTER the current one, calculated while walking
      nav.next_request = nil
      if e.path and #e.path > 0 and nav.next_start and data.entity and data.entity.valid then
        local list = densify(e.path, nav.next_start)
        if #list == 0 then list = {{x = e.path[#e.path].position.x, y = e.path[#e.path].position.y}} end
        nav.next = {points = list, goal = nav.next_goal, final = nav.next_final, accept = nav.next_accept}
        draw_route(pindex, data, nav.next_start, list)
      elseif e.try_again_later then
        nav.next_retry = game.tick + REQUEST_COOLDOWN
      else
        nav.next_bias = (nav.next_bias or 0) + 1 -- another goal for the next hop (see hop_goal)
        nav.next_retry = game.tick + 30
      end
      return
    end
  end
end

-- every task walks through this: vehicles.wrap decides whether to drive (scripts/vehicles.lua) or call M.walk
common.walker = vehicles.wrap(M.walk)

return M
