-- Objective "power": make sure at least `goal_kw` of generation exists.
--
-- Flow (all state lives in the zones, so an interruption just resumes):
--   1. If the force already has any generator on the surface and we planned none -> satisfied.
--   2. Otherwise reserve a ZONE, starting with ONLY the offshore pump (placed first, as the starting
--      point); once the pump has a ghost, search for a spot for the rest of the plant and grow the zone:
--        steam : offshore pump + pipes + boilers (+ fuel) + steam engines, laid out from the
--                pump's real fluidbox connection points (read from the prototypes)
--        solar : a block of solar panels (used when steam isn't available / no water nearby)
--   3. Every step: make sure each planned entity exists as a ghost or building INSIDE the zone,
--      wait for the normal auto-build tasks to build them (scripts/upkeep.lua keeps the boilers fuelled).
--   4. If the goal later grows beyond the zones' capacity, a further zone is planned.

local geometry = require("scripts.geometry")
local zones    = require("scripts.zones")
local debug    = require("scripts.debug")
local config   = require("scripts.layout_config")

local PURPOSE = "power"

-- Rated output in kW. Solar is the day/night average (peak is 60 kW).
local ENGINE_KW, SOLAR_KW = 900, 42
local ENGINES_PER_BOILER = 2
local WATER_CLEARANCE = config.water_clearance or 3        -- min free-of-water tiles around the boilers and engines
local PUMP_SEARCH_RADIUS = config.pump_search_radius or 120
local PUMP_SITE_SPACING = 4      -- after a pump site is given up on, the next pump keeps this distance from it
local MAX_PUMP_TESTS = 2000
local MIN_PIPES = config.min_pipes or 3              -- shortest pipe run between the pump and the first boiler
local MAX_PIPES = config.max_pipes or 30             -- longest pipe run we are willing to build

local DIR = defines.direction

local ENGINE_LEN = 5 -- tiles along its axis (3 x 5)
do
  local ok, w, h = pcall(geometry.footprint, "steam-engine")
  if ok and w and h then ENGINE_LEN = math.max(w, h) end
end
if config.engine_length then ENGINE_LEN = config.engine_length end

---------------------------------------------------------------------
-- Planning helpers
---------------------------------------------------------------------

local function recipes_enabled(force, names)
  for _, n in ipairs(names) do
    local r = force.recipes[n]
    if not (r and r.enabled) then return false, n end
  end
  return true
end

local function has_any_producer(surface, force)
  return surface.count_entities_filtered{
    type = {"generator", "solar-panel", "fusion-generator", "burner-generator"}, force = force, limit = 1,
  } > 0
end

-- Does any tile under this entry (rotated footprint) hold water?
local function entry_on_water(surface, e)
  local w, h = geometry.footprint(e.name)
  if e.direction == DIR.east or e.direction == DIR.west then w, h = h, w end
  local area = {{e.x - w / 2 + 0.1, e.y - h / 2 + 0.1}, {e.x + w / 2 - 0.1, e.y + h / 2 - 0.1}}
  local ok, n = pcall(function()
    return surface.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1}
  end)
  return ok and n > 0
end

-- Is there water within WATER_CLEARANCE tiles of this entry's footprint?
local function entry_near_water(surface, e)
  local w, h = geometry.footprint(e.name)
  if e.direction == DIR.east or e.direction == DIR.west then w, h = h, w end
  local m = WATER_CLEARANCE
  local area = {{e.x - w / 2 - m, e.y - h / 2 - m}, {e.x + w / 2 + m, e.y + h / 2 + m}}
  local ok, n = pcall(function()
    return surface.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1}
  end)
  return ok and n > 0
end

-- Is the area free enough to place a ghost of every planned entry?
-- Ghosts can be dropped on water, so water is checked here on purpose: only the offshore pump
-- (skip_name) may touch it. The "plant" (boilers + engines) must also keep WATER_CLEARANCE tiles
-- from the water and be free of ore; the pump and the pipe run leading to it are exempt from that.
-- Returns true, or false + a short reason (counted in `stats` for the debug output).
local function layout_is_free(player, surface, force, entries, skip_name, own_zone)
  local plant = {}
  -- cheap rejections first: the plant (boilers + engines) must be dry and keep its distance from water
  for _, e in ipairs(entries) do
    if e.name ~= skip_name and e.name ~= "pipe" then
      if entry_on_water(surface, e) then return false, "plant_on_water" end
      if entry_near_water(surface, e) then return false, "plant_near_water" end
      plant[#plant + 1] = e
    end
  end
  for _, e in ipairs(entries) do
    if e.name == "pipe" and entry_on_water(surface, e) then return false, "pipe_on_water" end
  end
  if #plant > 0 then
    local x0, y0, x1, y1 = geometry.bbox_of(plant, 1)
    if surface.count_entities_filtered{area = {{x0, y0}, {x1, y1}}, type = "resource", limit = 1} > 0 then
      return false, "ore"
    end
  end
  for _, e in ipairs(entries) do
    if e.name ~= skip_name then
      local ok = surface.can_place_entity{
        name = e.name, position = {e.x, e.y}, direction = e.direction, force = force,
        build_check_type = defines.build_check_type.ghost_place,
      }
      if not ok then return false, "cannot_place_" .. e.name end
    end
  end
  local x0, y0, x1, y1 = geometry.bbox_of(entries, 1)
  if zones.overlaps_any(player.index, surface.index, {x0 = x0, y0 = y0, x1 = x1, y1 = y1}, own_zone) then
    return false, "zone_overlap"
  end
  return true
end

---------------------------------------------------------------------
-- Step 1: the offshore pump (placed first, it is the starting point of the plant)
---------------------------------------------------------------------

local function rejected_sites(player)
  storage.power_rejected = storage.power_rejected or {}
  storage.power_rejected[player.index] = storage.power_rejected[player.index] or {}
  return storage.power_rejected[player.index]
end

local function near_rejected(list, x, y)
  for _, r in ipairs(list) do
    if math.abs(r.x - x) < PUMP_SITE_SPACING and math.abs(r.y - y) < PUMP_SITE_SPACING then return true end
  end
  return false
end

-- Centre of the tile containing v.
local function snap_tile(v) return math.floor(v) + 0.5 end

-- Unit vector the pump's output points to for a pump direction, when the game can't tell
-- (the pump faces the water; its output is on the opposite side).
local function site_vector(dir)
  if dir == DIR.north then return 0, 1 elseif dir == DIR.south then return 0, -1
  elseif dir == DIR.east then return -1, 0 else return 1, 0 end
end

-- Does the tile centred on (tx, ty) overlap the box? (touching edges do not count)
local function tile_overlaps_box(tx, ty, box)
  local eps = 0.02
  return tx + 0.5 > box.left_top.x + eps and tx - 0.5 < box.right_bottom.x - eps
     and ty + 0.5 > box.left_top.y + eps and ty - 0.5 < box.right_bottom.y - eps
end

-- Where the pump's output REALLY is. A throw-away pump is created at the spot and the game is asked
-- for its pipe connection (nothing about it is guessed from the prototype or the shore), then it is
-- destroyed again. The first pipe goes on the tile the connection points at; it is checked against
-- the pump's real collision box so it can never end up inside the pump.
-- Returns {x, y (pump as placed), direction, out_x, out_y, land_x, land_y} or nil.
local function probe_pump(surface, force, px, py, dir)
  local called, pump = pcall(function()
    return surface.create_entity{name = "offshore-pump", position = {px, py}, direction = dir, force = force}
  end)
  if not (called and pump and pump.valid) then return nil end

  local result
  local ok = pcall(function()
    local pos, box = pump.position, pump.bounding_box
    local tx, ty -- the tile the game says the connection leads to
    local fb = pump.fluidbox
    local conns = fb and fb.get_pipe_connections(1)
    local c = conns and conns[1]
    if c then
      local t = c.target_position or c.position
      if t then tx, ty = snap_tile(t.x), snap_tile(t.y) end
    end

    -- direction pump -> output: from the connection when known, else from the pump's orientation
    local vx, vy
    if tx then vx, vy = geometry.unit(tx - pos.x, ty - pos.y) end
    if not vx then vx, vy = geometry.unit(site_vector(dir)) end

    -- walk from the pump's own tile along v until the tile is clear of the pump's body
    local mx, my = snap_tile(pos.x), snap_tile(pos.y)
    for _ = 1, 4 do
      if not tile_overlaps_box(mx, my, box) then break end
      mx, my = mx + vx, my + vy
    end

    -- the game's own answer wins when it is a tile outside the pump next to the walked one
    local ox, oy = mx, my
    if tx and not tile_overlaps_box(tx, ty, box) and math.abs(tx - mx) + math.abs(ty - my) <= 1.01 then
      ox, oy = tx, ty
    end
    result = {x = pos.x, y = pos.y, direction = pump.direction, out_x = ox, out_y = oy,
              land_x = vx, land_y = vy, target_x = tx, target_y = ty}
  end)
  pump.destroy()
  return ok and result or nil
end

-- Asks the game whether an offshore pump may stand here with this orientation. The "manual" checks
-- are the ones a player's placement goes through (they include the pump's own rule that its input end
-- must be in water); the plain ghost check is the fallback if they are not available.
-- Returns a site table or nil.
local function pump_placement(surface, force, px, py, dir, lx, ly, v)
  local ok = false
  local used
  for _, check in ipairs({"manual_ghost", "manual", "ghost_place"}) do
    local bct = defines.build_check_type[check]
    if bct then
      local called, res = pcall(function()
        return surface.can_place_entity{
          name = "offshore-pump", position = {px, py}, direction = dir, force = force, build_check_type = bct,
        }
      end)
      if called then ok, used = res, check; break end
    end
  end
  if not ok then return nil end

  -- Ground truth: where the pump's output is once the pump really stands there (see probe_pump).
  local probe = probe_pump(surface, force, px, py, dir)
  local site
  if probe then
    site = {
      x = probe.x, y = probe.y, direction = probe.direction, check = used,
      land_x = probe.land_x, land_y = probe.land_y, out_x = probe.out_x, out_y = probe.out_y,
      probed = true,
    }
  else
    -- fallback (probing failed): the land tile right behind the shore tile, in line with the pump
    site = {
      x = px, y = py, direction = dir, land_x = v[1], land_y = v[2], check = used,
      out_x = lx + 0.5 + v[1], out_y = ly + 0.5 + v[2],
    }
  end
  local off = config.pump_output_offset and config.pump_output_offset[dir]
  if off then
    site.out_x, site.out_y = px + off[1], py + off[2]
    site.land_x, site.land_y = geometry.unit(off[1], off[2])
  end
  local tile = surface.get_tile(math.floor(site.out_x), math.floor(site.out_y))
  if not tile.valid or tile.collides_with("water_tile") then return nil end
  -- the first pipe must be placeable there (not inside the pump, not on a tree/rock/cliff)
  local can = surface.can_place_entity{
    name = "pipe", position = {site.out_x, site.out_y}, force = force,
    build_check_type = defines.build_check_type.ghost_place,
  }
  if not can then return nil end
  return site
end

-- The nearest valid offshore-pump placement around `center` (skipping sites already given up on).
-- The pump goes right on the shore: no offset from the water. Returns site | nil, stats.
local function find_pump_site(player, surface, force, center)
  local stats = {water_tiles = 0, tested = 0, cannot_place = 0, rejected = 0, radius = 0}
  local rejected = rejected_sites(player)

  -- widen the search so the NEAREST shore is found first
  local water
  for _, radius in ipairs({16, 32, 64, PUMP_SEARCH_RADIUS}) do
    local ok, found = pcall(function()
      return surface.find_tiles_filtered{
        position = center, radius = radius, collision_mask = "water_tile", limit = 3000,
      }
    end)
    stats.radius = radius
    if ok and found and #found > 0 then water = found; break end
  end
  if not water then return nil, stats end
  stats.water_tiles = #water

  local tiles = {}
  for _, t in ipairs(water) do
    local dx, dy = t.position.x + 0.5 - center.x, t.position.y + 0.5 - center.y
    tiles[#tiles + 1] = {x = t.position.x, y = t.position.y, d = dx * dx + dy * dy}
  end
  table.sort(tiles, function(a, b) return a.d < b.d end)

  local seen = {}
  for i = 1, math.min(#tiles, 1500) do
    local wx, wy = tiles[i].x, tiles[i].y
    for _, v in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
      local lx, ly = wx + v[1], wy + v[2]
      local land = surface.get_tile(lx, ly)
      if not land.collides_with("water_tile") then
        for _, shift in ipairs({0, 0.5}) do
          local px, py = lx + 0.5 - v[1] * shift, ly + 0.5 - v[2] * shift
          for _, dir in ipairs({DIR.north, DIR.east, DIR.south, DIR.west}) do
            local k = px .. "," .. py .. "," .. dir
            if not seen[k] and stats.tested < MAX_PUMP_TESTS then
              seen[k] = true
              if near_rejected(rejected, px, py) then
                stats.rejected = stats.rejected + 1
              else
                stats.tested = stats.tested + 1
                -- the game decides which orientation is valid, exactly like when a player places the pump
                -- (the water must be at its input end); our own geometry is only a sanity check
                local site = pump_placement(surface, force, px, py, dir, lx, ly, v)
                if site then
                  stats.check = site.check
                  return site, stats
                end
                stats.cannot_place = stats.cannot_place + 1
              end
            end
          end
        end
      end
    end
  end
  return nil, stats
end

local function on_grid(v) return math.abs((v * 2) % 2 - 1) < 0.01 end -- v is a tile centre (x.5)

---------------------------------------------------------------------
-- Step 2: the plant, searched for around an existing pump
---------------------------------------------------------------------

-- Steam layout for one pump site and one plant position. The pipe leaves the pump straight for
-- `a` tiles, optionally turns and runs `b` more tiles towards the plant (direction `v`), and ends at
-- the first boiler's water inlet.
-- Local frame (before rotation): boilers in a row, engines stacked "north" of each boiler, water
-- entering the first boiler's west end; the plant is rotated so "north" is the last pipe direction.
local function steam_layout(site, n_boilers, n_engines, a, v, b)
  local Ox, Oy, ux, uy = site.out_x, site.out_y, site.land_x, site.land_y  -- tile in front of the pump + its direction
  if not Ox then -- a zone saved by an older version: fall back to the prototype's connection data
    local pc = geometry.connections("offshore-pump", site.direction)[1]
    if not pc then return nil, "no_pump_connection" end
    Ox, Oy, ux, uy = site.x + pc.x, site.y + pc.y, pc.dx, pc.dy
  end
  if not (on_grid(Ox) and on_grid(Oy)) then return nil, "pump_output_off_grid" end

  local vx, vy = v[1], v[2]                           -- direction of the last pipe segment
  if b == 0 then vx, vy = ux, uy end
  local turns = geometry.dir_to_turns(geometry.vec_to_dir(vx, vy))
  local bdir  = geometry.turns_to_dir(turns)
  local edir  = geometry.vec_to_dir(vx, vy)

  -- boiler: two-ended water fluidbox, one-ended steam output
  local water_in, steam
  local win_x, win_y = geometry.rotate(-1, 0, turns)  -- the end that faces the pipe run
  if config.boiler then
    local ww, st = config.boiler.water_west, config.boiler.steam
    local wx, wy = geometry.rotate(ww[1], ww[2], turns)
    local sx, sy = geometry.rotate(st[1], st[2], turns)
    local sdx, sdy = geometry.rotate(0, -1, turns)
    water_in = {x = wx, y = wy, dx = win_x, dy = win_y}
    steam = {x = sx, y = sy, dx = sdx, dy = sdy}
  else
    for _, c in ipairs(geometry.connections("boiler", bdir)) do
      if c.count == 2 then
        if c.dx == win_x and c.dy == win_y then water_in = c end
      elseif c.count == 1 then
        steam = c
      end
    end
  end
  if not (water_in and steam) then return nil, "boiler_connections_not_found" end
  -- the steam must leave the boiler along the pipe direction, or the engines would not line up
  if steam.dx ~= vx or steam.dy ~= vy then return nil, "boiler_steam_not_aligned" end

  local entries = {{name = "offshore-pump", x = site.x, y = site.y, direction = site.direction}}
  for i = 0, a do
    entries[#entries + 1] = {name = "pipe", x = Ox + ux * i, y = Oy + uy * i, direction = DIR.north}
  end
  local Qx, Qy = Ox + ux * a, Oy + uy * a
  for _ = 1, b do
    Qx, Qy = Qx + vx, Qy + vy
    entries[#entries + 1] = {name = "pipe", x = Qx, y = Qy, direction = DIR.north}
  end

  local B0x, B0y = Qx - water_in.x, Qy - water_in.y                      -- last pipe touches the boiler
  local rx, ry = geometry.rotate(1, 0, turns)                           -- along the boiler row
  local left = n_engines
  for bi = 0, n_boilers - 1 do
    local bx, by = B0x + rx * 3 * bi, B0y + ry * 3 * bi
    entries[#entries + 1] = {name = "boiler", x = bx, y = by, direction = bdir}
    -- the engine's first tile is the neighbour tile of the boiler's steam output; its centre is
    -- half the engine's length further on (so the two never share a tile)
    local ex, ey = bx + steam.x + vx * (ENGINE_LEN - 1) / 2, by + steam.y + vy * (ENGINE_LEN - 1) / 2
    for _ = 1, math.min(ENGINES_PER_BOILER, left) do
      entries[#entries + 1] = {name = "steam-engine", x = ex, y = ey, direction = edir}
      ex, ey = ex + vx * ENGINE_LEN, ey + vy * ENGINE_LEN
      left = left - 1
    end
  end
  return entries
end

-- Candidate pipe routes from one pump, shortest first: {a, v, b}. Straight runs, then L-shaped
-- runs that turn left or right after `a` tiles.
local function pipe_routes(site)
  local ux, uy = site.land_x, site.land_y
  if not ux then
    local pc = geometry.connections("offshore-pump", site.direction)[1]
    if not pc then return {} end
    ux, uy = pc.dx, pc.dy
  end
  local routes = {}
  for a = MIN_PIPES - 1, MAX_PIPES - 1 do
    routes[#routes + 1] = {a = a, v = {ux, uy}, b = 0, len = a + 1}
  end
  for _, v in ipairs({{-uy, ux}, {uy, -ux}}) do
    for _, a in ipairs({1, 3, 6}) do
      for b = 1, MAX_PIPES - a - 1 do
        routes[#routes + 1] = {a = a, v = v, b = b, len = a + b + 1}
      end
    end
  end
  table.sort(routes, function(x, y) return x.len < y.len end)
  return routes
end

-- Look for a spot for the boilers + engines around the zone's pump. Returns entries | nil, stats.
local function find_plant(ctx, zone)
  local surface, force = game.get_surface(zone.surface_index), ctx.player.force
  local stats = {routes = 0, reasons = {}}
  for _, r in ipairs(pipe_routes(zone.site)) do
    stats.routes = stats.routes + 1
    local entries, why = steam_layout(zone.site, zone.n_boilers, zone.n_engines, r.a, r.v, r.b)
    local ok = entries ~= nil
    if ok then ok, why = layout_is_free(ctx.player, surface, force, entries, "offshore-pump", zone) end
    if ok then
      stats.pipes = r.len
      return entries, stats
    end
    stats.reasons[why] = (stats.reasons[why] or 0) + 1
  end
  return nil, stats
end

local function plan_solar(ctx, goal_kw)
  local surface, force = ctx.surface, ctx.player.force
  local n = math.max(1, math.ceil(goal_kw / SOLAR_KW))
  local cols = math.ceil(math.sqrt(n))
  local rows = math.ceil(n / cols)
  local w, h = geometry.footprint("solar-panel")
  local box = zones.find_site(ctx.player.index, surface, force, cols * w + 2, rows * h + 2,
    ctx.data.entity.position, 80)
  if not box then return nil, "no free area for solar panels nearby" end

  local entries = {}
  for i = 0, n - 1 do
    local c, r = i % cols, math.floor(i / cols)
    entries[#entries + 1] = {
      name = "solar-panel", direction = DIR.north,
      x = box.x0 + 1 + c * w + w / 2, y = box.y0 + 1 + r * h + h / 2,
    }
  end
  return {mode = "solar", entries = entries, capacity_kw = n * SOLAR_KW}
end

local function make_plan(ctx, goal_kw)
  local surface, force = ctx.surface, ctx.player.force
  local steam_ok, missing = recipes_enabled(force, {"offshore-pump", "boiler", "steam-engine", "pipe"})
  local solar_ok = recipes_enabled(force, {"solar-panel"})
  local err
  if steam_ok then
    -- Offshore pump first: it is placed as soon as a valid shore spot exists. The rest of the
    -- plant is searched around it afterwards (see tend_zone).
    local site, stats = find_pump_site(ctx.player, surface, force, ctx.data.entity.position)
    if site then
      local n_engines = math.max(1, math.ceil(goal_kw / ENGINE_KW))
      debug.say(ctx.player, string.format(
        "pump site found at (%.1f, %.1f) facing %d [water tiles seen: %d within %d tiles, spots tested: %d, invalid: %d, skipped: %d]",
        site.x, site.y, site.direction, stats.water_tiles, stats.radius, stats.tested, stats.cannot_place, stats.rejected))
      debug.say(ctx.player, string.format(
        "pump output: first pipe at (%.1f, %.1f), pump pointing (%d, %d); fluidbox delta=%.1f; orientation accepted by the game check: %s",
        site.out_x, site.out_y, site.land_x, site.land_y, geometry.position_delta(), tostring(stats.check)))
      debug.mark(ctx.player, surface, {x = site.out_x, y = site.out_y}, {r = 1, g = 1, b = 0, a = 0.8}, "first pipe", 3600, 0.35)
      debug.mark(ctx.player, surface, {x = site.x, y = site.y}, {r = 0, g = 1, b = 0, a = 0.8}, "pump", 3600, 0.5)
      return {
        mode = "steam",
        entries = {{name = "offshore-pump", x = site.x, y = site.y, direction = site.direction}},
        capacity_kw = n_engines * ENGINE_KW,
        extra = {phase = "pump", site = site, n_engines = n_engines,
                 n_boilers = math.ceil(n_engines / ENGINES_PER_BOILER)},
      }
    end
    if stats.water_tiles == 0 then
      err = "no water within " .. PUMP_SEARCH_RADIUS .. " tiles (only charted/generated terrain is searched)"
    else
      err = string.format("water found but no valid offshore pump spot (%d water tiles, %d spots tested, %d invalid, %d skipped as already tried)",
        stats.water_tiles, stats.tested, stats.cannot_place, stats.rejected)
    end
    debug.say(ctx.player, "pump search failed: " .. err)
    if not solar_ok then return nil, err end
  else
    err = "steam power needs the recipe '" .. tostring(missing) .. "'"
    debug.say(ctx.player, err)
  end
  if solar_ok then return plan_solar(ctx, goal_kw) end
  return nil, err or "no generator is researched yet"
end

---------------------------------------------------------------------
-- Tending a zone: pump -> plant search -> ghosts -> buildings (fuel is handled for every zone by scripts/upkeep.lua)
---------------------------------------------------------------------

-- Give up on this zone's pump spot: drop the (unbuilt) pump ghost and the zone, remember the spot.
local function abandon_pump(ctx, zone, surface, force)
  for _, f in pairs(zones.index_entities(zone, force)) do
    if f.ghost and f.entity.valid then f.entity.destroy() end
  end
  local list = rejected_sites(ctx.player)
  list[#list + 1] = {x = zone.site.x, y = zone.site.y}
  if #list > 60 then table.remove(list, 1) end
  zones.remove(ctx.player.index, zone.purpose)
end

local function tend_zone(ctx, zone)
  local surface = game.get_surface(zone.surface_index)
  if not surface then return "blocked", "the power zone's surface no longer exists" end
  local force = ctx.player.force

  local built, pending, failed = zones.ensure_ghosts(zone, surface, force)

  if zone.phase == "pump" then
    if failed > 0 then
      debug.say(ctx.player, "the pump ghost could not be placed; trying another pump spot")
      abandon_pump(ctx, zone, surface, force)
      return "working", "pump ghost rejected, picking another spot"
    end
    if game.tick >= (zone.next_plant_try or 0) then
      local entries, stats = find_plant(ctx, zone)
      if entries then
        zones.set_entries(ctx.player, zone, entries)
        zone.phase = "plant"
        storage.power_rejected[ctx.player.index] = {}
        debug.say(ctx.player, string.format(
          "plant spot found after %d routes: %d pipes from the pump, %d boilers, %d engines",
          stats.routes, stats.pipes, zone.n_boilers, zone.n_engines))
        for _, e in ipairs(entries) do
          if e.name ~= "pipe" then
            debug.say(ctx.player, string.format("  %s at (%.1f, %.1f) direction %d", e.name, e.x, e.y, e.direction))
          end
        end
        return "working", "pump planned, plant spot found"
      end
      zone.next_plant_try = game.tick + 300
      debug.say(ctx.player, string.format("no plant spot around the pump at (%.1f, %.1f): %d routes tried (%s)",
        zone.site.x, zone.site.y, stats.routes, debug.counts(stats.reasons)))
      debug.mark(ctx.player, surface, {x = zone.site.x, y = zone.site.y}, {r = 1, g = 0.2, b = 0.2, a = 0.8}, "no plant spot", 3600, 0.5)
      if built == 0 then
        -- the pump is only a ghost: pick a different spot rather than build a useless pump
        abandon_pump(ctx, zone, surface, force)
        return "working", "no room for a plant at this pump, trying another spot"
      end
      return "blocked", "pump is built but there is no room for the plant near it (" .. debug.counts(stats.reasons) .. ")"
    end
    return "working", "pump placed, waiting to search for the plant spot"
  end

  if failed > 0 then
    return "blocked", string.format("%d planned power entities can't be placed (something in the way?)", failed)
  end
  if pending > 0 then
    return "working", string.format("power zone: waiting for %d ghosts to be built (%d built)", pending, built)
  end

  return "satisfied", string.format("%d kW online (%s)", zone.capacity_kw, zone.mode)
end

---------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------

return {
  id = "power",
  caption = "Power plant",
  implemented = true,

  step = function(ctx)
    local player = ctx.player
    ctx.surface = ctx.data.entity.surface
    local goal = ctx.params.goal_kw or 60

    local existing = zones.list(player.index, PURPOSE)
    local total = 0
    for _, zone in ipairs(existing) do
      local status, note = tend_zone(ctx, zone)
      if status ~= "satisfied" then return status, note end
      total = total + zone.capacity_kw
    end

    if #existing == 0 and has_any_producer(ctx.surface, player.force) then
      return "satisfied", "a power plant already exists"
    end
    if total >= goal then
      return "satisfied", string.format("%d of %d kW", total, goal)
    end

    local plan, err = make_plan(ctx, goal - total)
    if not plan then return "blocked", "cannot plan power: " .. err end

    local extra = {goal_kw = goal, capacity_kw = plan.capacity_kw, mode = plan.mode}
    for k, v in pairs(plan.extra or {}) do extra[k] = v end
    zones.create(player, zones.next_purpose(player.index, PURPOSE), ctx.surface, plan.entries, extra)
    if plan.mode == "steam" then
      return "working", "offshore pump zone assigned (the plant is planned around it next)"
    end
    return "working", string.format("assigned a %s power zone (+%d kW)", plan.mode, plan.capacity_kw)
  end,
}
