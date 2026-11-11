-- Objective "factory_supply": connects the furnaces to the assemblers of a factory so the plates stop
-- being carried by hand.
--
--   furnaces --[inserter]--> belt ----------------------> belt row along the machines --[inserter]--> assemblers
--
-- It EXTENDS the existing factory zone (like lab_expansion extends the lab zone) and creates one extra zone,
-- "factory_supply", for the belt line and the furnace inserters. Phases, kept in zone.supply of the factory:
--
--   row       the input side of the factory is worked out (the side away from the output inserters / chest):
--             a belt row 3 tiles from the machines, an inserter per machine that takes `item` by hand
--             (belt -> machine) and a pole between them. They are added to the factory zone's entries.
--   route     one furnace after the other gets a belt path to the row (A* over the tiles, budgeted per tick,
--             avoiding other zones, water, buildings; a path may end on a belt that is already planned,
--             so the lines merge by side-loading). Nothing is placed yet except the plan.
--   belts     the belt ghosts are built (the plates stay in the furnaces meanwhile: the companion needs them).
--   inserters the inserters that take the plates out of the furnaces are added and built (burner inserters:
--             no power at the ore, upkeep.lua keeps them fuelled like every other burner in a zone).
--   done      the machines no longer count `item` as a hand-fed ingredient: the companion stops carrying it.
--
-- Params (playbook): factory (zone purpose, default "belt_factory"), item (default "iron-plate"),
-- source (zone purpose of the furnaces, default "iron_start").

local zones    = require("scripts.zones")
local geometry = require("scripts.geometry")
local lab      = require("scripts.objectives.lab")
local debug    = require("scripts.debug")

local BELT = "transport-belt"
local INSERTER = "inserter"
local BURNER_INSERTER = "burner-inserter"
local SUPPLY_PURPOSE = "factory_supply"

local BUDGET = 2500          -- nodes expanded per evaluation
local MAX_EXPANSIONS = 90000 -- nodes expanded for ONE furnace before it is given up
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

---------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------

local function tkey(tx, ty) return tx .. "," .. ty end

local function is_pole(name)
  local proto = prototypes.entity[name]
  return proto ~= nil and proto.type == "electric-pole"
end

local function entry_entity(found, e)
  local f = found[zones.key(e.name, {x = e.x, y = e.y})]
  return f and not f.ghost and f.entity.valid and f.entity or nil
end

local function centroid(list)
  local x, y = 0, 0
  for _, e in ipairs(list) do x, y = x + e.x, y + e.y end
  return x / #list, y / #list
end

-- Tiles taken by entries, added to `set`.
local function block_tiles(set, entries)
  for _, e in ipairs(entries) do
    local w, h = geometry.footprint(e.name)
    local x0, y0 = math.floor(e.x - w / 2 + 0.01), math.floor(e.y - h / 2 + 0.01)
    for i = 0, w - 1 do
      for j = 0, h - 1 do set[tkey(x0 + i, y0 + j)] = true end
    end
  end
end

local function can_place(env, name, x, y, direction)
  return env.surface.can_place_entity{
    name = name, position = {x, y}, direction = direction, force = env.force,
    build_check_type = defines.build_check_type.ghost_place,
  }
end

-- Environment of one evaluation: which tiles are off limits, cached tile checks.
local function make_env(ctx, fz, sz, source)
  local surface, idx = ctx.surface, ctx.player.index
  local env = {surface = surface, force = ctx.player.force, cache = {}, blocked = {}, rects = {}}
  for _, z in ipairs(zones.all(idx)) do
    if z.surface_index == surface.index then
      local family = z.purpose:gsub("_%d+$", "")
      if family == source then
        block_tiles(env.blocked, z.entries or {}) -- the ore cells: only their own entries are in the way
      elseif z ~= fz and z ~= sz then
        env.rects[#env.rects + 1] = z
      end
    end
  end
  block_tiles(env.blocked, fz.entries)
  if sz then block_tiles(env.blocked, sz.entries) end
  return env
end

local function tile_ok(env, tx, ty)
  local k = tkey(tx, ty)
  local c = env.cache[k]
  if c ~= nil then return c end
  local ok = not env.blocked[k]
  if ok then
    local cx, cy = tx + 0.5, ty + 0.5
    for _, z in ipairs(env.rects) do
      if cx > z.x0 and cx < z.x1 and cy > z.y0 and cy < z.y1 then ok = false break end
    end
  end
  if ok then ok = env.surface.is_chunk_generated{x = math.floor(tx / 32), y = math.floor(ty / 32)} end
  if ok then ok = can_place(env, BELT, tx + 0.5, ty + 0.5, defines.direction.north) end
  env.cache[k] = ok
  return ok
end

---------------------------------------------------------------------
-- Phase "row": the input side of the factory
---------------------------------------------------------------------

-- Returns new entries, start tile {tx, ty}, flow {x, y}, served machines; or nil, reason.
local function plan_row(ctx, fz, item, near, source)
  local machines, others, served = {}, {}, {}
  for _, e in ipairs(fz.entries) do
    if e.recipe then
      machines[#machines + 1] = e
      for _, h in ipairs(e.hand or {}) do
        if h == item then served[#served + 1] = e break end
      end
    elseif not is_pole(e.name) and e.name ~= BELT then
      others[#others + 1] = e
    end
  end
  if #served == 0 then return nil, "no machine takes " .. item .. " by hand" end

  local mx, my = centroid(machines)
  local ox, oy = mx, my + 1
  if #others > 0 then ox, oy = centroid(others) end
  local dx, dy = geometry.unit(mx - ox, my - oy)   -- the input side: away from the output inserters / chest
  local ax, ay = -dy, dx                           -- the row runs along this axis

  -- machines standing in one line along the axis (the same distance from the input side)
  local base = served[1].x * dx + served[1].y * dy
  local row = {}
  for _, m in ipairs(served) do
    if math.abs(m.x * dx + m.y * dy - base) < 0.1 then row[#row + 1] = m end
  end
  local tmin, tmax = math.huge, -math.huge
  for _, m in ipairs(row) do
    local t = m.x * ax + m.y * ay
    tmin, tmax = math.min(tmin, t), math.max(tmax, t)
  end

  local function at(t, u) return ax * t + dx * u, ay * t + dy * u end
  local rcx, rcy = at((tmin + tmax) / 2, base + 3)
  local toward = (near.x - rcx) * ax + (near.y - rcy) * ay
  local start_t, fx, fy
  if toward >= 0 then start_t, fx, fy = tmax, -ax, -ay else start_t, fx, fy = tmin, ax, ay end
  local belt_dir = geometry.vec_to_dir(fx, fy)

  local entries = {}
  for t = tmin, tmax do
    local x, y = at(t, base + 3)
    entries[#entries + 1] = {name = BELT, x = x, y = y, direction = belt_dir}
  end
  for _, m in ipairs(row) do
    local t = m.x * ax + m.y * ay
    local x, y = at(t, base + 2)
    entries[#entries + 1] = {
      name = INSERTER, x = x, y = y, direction = geometry.vec_to_dir(dx, dy), -- picks up from the belt (outer side)
      drop = {x = x - dx, y = y - dy},
    }
  end
  -- poles between the inserters, so that every inserter has one within 2 tiles
  local pole_name = fz.pole or "small-electric-pole"
  local ins = {}
  for _, e in ipairs(entries) do if e.name == INSERTER then ins[#ins + 1] = e end end
  local poles_new = {}
  local function covered(e)
    for _, p in ipairs(poles_new) do
      if math.abs(p.x - e.x) <= 2 and math.abs(p.y - e.y) <= 2 then return true end
    end
    return false
  end
  local tm = tmin + math.floor((tmax - tmin) / 2)
  local px, py = at(tm, base + 2)
  if #ins == 1 or (px == ins[1].x and py == ins[1].y) then px, py = at(tm + 1, base + 2) end
  poles_new[1] = {name = pole_name, x = px, y = py, direction = defines.direction.north}
  for _, e in ipairs(ins) do
    if not covered(e) then
      local qx, qy = e.x + ax, e.y + ay
      poles_new[#poles_new + 1] = {name = pole_name, x = qx, y = qy, direction = defines.direction.north}
    end
  end
  for _, p in ipairs(poles_new) do entries[#entries + 1] = p end

  -- is everything free?
  local env = make_env(ctx, fz, nil, source)
  local taken = {}
  block_tiles(taken, fz.entries)
  for _, e in ipairs(entries) do
    local k = tkey(math.floor(e.x), math.floor(e.y))
    if taken[k] then return nil, "the input side of the factory is not free" end
    taken[k] = true
    for _, z in ipairs(env.rects) do
      if e.x > z.x0 and e.x < z.x1 and e.y > z.y0 and e.y < z.y1 then
        return nil, "the input side of the factory is inside another zone"
      end
    end
    if not can_place(env, e.name, e.x, e.y, e.direction) then
      return nil, "something is in the way on the input side of the factory"
    end
  end
  local sx, sy = at(start_t, base + 3)
  return entries, {tx = math.floor(sx), ty = math.floor(sy)}, {x = fx, y = fy}, row
end

---------------------------------------------------------------------
-- Phase "route": A* from a furnace to the row (or to a belt that already leads there)
---------------------------------------------------------------------

-- minimal binary heap of {f, k}
local function heap_push(h, f, k)
  h[#h + 1] = {f = f, k = k}
  local i = #h
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p].f <= h[i].f then break end
    h[p], h[i] = h[i], h[p]
    i = p
  end
end

local function heap_pop(h)
  local top = h[1]
  local last = table.remove(h)
  if #h > 0 then
    h[1] = last
    local i, n = 1, #h
    while true do
      local l, r, m = i * 2, i * 2 + 1, i
      if l <= n and h[l].f < h[m].f then m = l end
      if r <= n and h[r].f < h[m].f then m = r end
      if m == i then break end
      h[m], h[i] = h[i], h[m]
      i = m
    end
  end
  return top
end

local function split_key(k)
  local a, b = k:match("^(-?%d+),(-?%d+)$")
  return tonumber(a), tonumber(b)
end

-- Where does the inserter of this furnace go? The free spot (around the 2x2 furnace) nearest to the goal.
-- -> {ins = {x, y}, o = {x, y} (outwards), tx, ty (first belt tile)}
local function furnace_spot(env, furnace, goal)
  local fx, fy = furnace.x, furnace.y
  local cands = {
    {fx + 1.5, fy - 0.5, 1, 0}, {fx + 1.5, fy + 0.5, 1, 0},
    {fx - 1.5, fy - 0.5, -1, 0}, {fx - 1.5, fy + 0.5, -1, 0},
    {fx - 0.5, fy - 1.5, 0, -1}, {fx + 0.5, fy - 1.5, 0, -1},
    {fx - 0.5, fy + 1.5, 0, 1}, {fx + 0.5, fy + 1.5, 0, 1},
  }
  local best, best_d
  for _, c in ipairs(cands) do
    local ix, iy, ox, oy = c[1], c[2], c[3], c[4]
    local itx, ity = math.floor(ix), math.floor(iy)
    local dtx, dty = math.floor(ix + ox), math.floor(iy + oy)
    if tile_ok(env, dtx, dty) and not env.blocked[tkey(itx, ity)]
      and can_place(env, BURNER_INSERTER, ix, iy, geometry.vec_to_dir(-ox, -oy)) then
      local d = math.abs(dtx - goal.tx) + math.abs(dty - goal.ty)
      if not best or d < best_d then best, best_d = {ins = {x = ix, y = iy}, o = {x = ox, y = oy}, tx = dtx, ty = dty}, d end
    end
  end
  return best
end

-- One furnace: runs up to BUDGET expansions of the search kept in `search`. -> "found", path, goal | "failed" | "running"
local function run_search(env, search, goals, goal_map)
  local g, parent, heap = search.g, search.parent, search.heap

  local function h(tx, ty)
    local best = math.huge
    for _, s in ipairs(search.samples) do
      best = math.min(best, math.abs(tx - s.tx) + math.abs(ty - s.ty))
    end
    return best
  end

  if not search.started then
    search.started = true
    local k = tkey(search.start.tx, search.start.ty)
    g[k] = 0
    heap_push(heap, h(search.start.tx, search.start.ty), k)
  end

  local budget = BUDGET
  while budget > 0 and #heap > 0 do
    local top = heap_pop(heap)
    local k = top.k
    if not search.closed[k] then
      search.closed[k] = true
      budget = budget - 1
      search.expansions = search.expansions + 1
      local tx, ty = split_key(k)

      -- finished: next to a goal tile, not entering it head-on
      for _, d in ipairs(DIRS) do
        local gk = tkey(tx + d[1], ty + d[2])
        local goal = goal_map[gk]
        if goal and not (d[1] == -goal.fx and d[2] == -goal.fy) then
          local path, cur = {}, k
          while cur do
            table.insert(path, 1, cur)
            cur = parent[cur]
          end
          return "found", path, {x = d[1], y = d[2]}
        end
      end

      for _, d in ipairs(DIRS) do
        local nx, ny = tx + d[1], ty + d[2]
        local nk = tkey(nx, ny)
        if not search.closed[nk] and tile_ok(env, nx, ny) then
          local ng = g[k] + 1
          if not g[nk] or ng < g[nk] then
            g[nk] = ng
            parent[nk] = k
            heap_push(heap, ng + h(nx, ny), nk)
          end
        end
      end
    end
  end
  if #heap == 0 or search.expansions > MAX_EXPANSIONS then return "failed" end
  return "running"
end

-- Goal tiles: the start of the row + every belt of the line planned so far.
local function make_goals(sup, sz)
  local goals, map = {}, {}
  local function add(tx, ty, fx, fy)
    local goal = {tx = tx, ty = ty, fx = fx, fy = fy}
    goals[#goals + 1] = goal
    map[tkey(tx, ty)] = goal
  end
  add(sup.start.tx, sup.start.ty, sup.flow.x, sup.flow.y)
  if sz then
    for _, e in ipairs(sz.entries) do
      if e.name == BELT then
        local fx, fy = 0, 0
        if e.direction == defines.direction.east then fx = 1
        elseif e.direction == defines.direction.west then fx = -1
        elseif e.direction == defines.direction.south then fy = 1
        else fy = -1 end
        add(math.floor(e.x), math.floor(e.y), fx, fy)
      end
    end
  end
  -- a few of them are enough for the heuristic
  local samples, step = {}, math.max(1, math.floor(#goals / 8))
  for i = 1, #goals, step do samples[#samples + 1] = goals[i] end
  samples[#samples + 1] = goals[1]
  return goals, map, samples
end

---------------------------------------------------------------------
-- Helpers for the phases that wait for the ghosts
---------------------------------------------------------------------

local function wait_for_zone(ctx, zone, caption)
  local surface = game.get_surface(zone.surface_index)
  local _, _, failed, found = zones.ensure_ghosts(zone, surface, ctx.player.force)
  if failed > 0 then return "blocked", "the " .. caption .. " can't be completed (something in the way?)" end
  local missing, pending = {}, 0
  for _, e in ipairs(zone.entries) do
    if not entry_entity(found, e) then
      missing[e.name] = (missing[e.name] or 0) + 1
      pending = pending + 1
    end
  end
  if pending == 0 then return nil, nil, found end
  if ctx.data.task then return "working", "busy: " .. (ctx.data.status or "task") end
  local status, note = lab.provide_materials(ctx, missing)
  if status then return status, note end
  return "working", string.format("waiting for %d %s ghosts to be built", pending, caption)
end

local function fix_inserters(zone, found)
  for _, e in ipairs(zone.entries) do
    if e.drop then
      local ins = entry_entity(found, e)
      local dp = ins and ins.drop_position
      if dp and (math.abs(dp.x - e.drop.x) > 0.8 or math.abs(dp.y - e.drop.y) > 0.8) then
        local turned = (ins.direction + 8) % 16
        if pcall(function() ins.direction = turned end) then e.direction = turned end
      end
    end
  end
end

local function copy_entries(list)
  local out = {}
  for _, e in ipairs(list) do out[#out + 1] = e end
  return out
end

---------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------

return {
  id = "factory_supply",
  caption = "Furnaces connected to the factory",
  implemented = true,
  upkeep_scope = {"iron_start", "coal", "power", "factory_supply"}, -- the iron burners, the power plant, the furnace inserters

  step = function(ctx)
    local player, data = ctx.player, ctx.data
    local force, idx = player.force, player.index
    ctx.surface = data.entity.surface
    local params = ctx.params or {}
    local item = params.item or "iron-plate"
    local source = params.source or "iron_start"

    local fz = zones.list(idx, params.factory or "belt_factory")[1]
    if not fz then return "satisfied", "no factory to connect yet" end
    -- a factory placed from a player's blueprint brings its own layout: this objective only knows the built-in
    -- one, so it leaves the blueprint zone alone (its raw ingredients stay hand-fed, see factory_base.lua)
    if fz.bp_str then return "satisfied", "blueprint factory: not connected by this objective" end
    local sup = fz.supply
    if sup and sup.phase == "done" then return "satisfied", "the furnaces feed the factory" end

    local bi = force.recipes[BELT]
    if not (bi and bi.enabled) then return "satisfied", BELT .. " is not available yet" end
    local br = force.recipes[BURNER_INSERTER]
    if not (br and br.enabled) then return "satisfied", BURNER_INSERTER .. " is not available yet" end

    -- the factory must stand (the factory objective builds it)
    local surface = game.get_surface(fz.surface_index)
    local found = zones.index_entities(fz, force)
    for _, e in ipairs(fz.entries) do
      if not entry_entity(found, e) then return "satisfied", "waiting for the factory to be built" end
    end

    -- the furnaces
    local furnaces = {}
    for _, z in ipairs(zones.list(idx, source)) do
      for _, f in pairs(zones.index_entities(z, force)) do
        if not f.ghost and f.entity.valid and f.entity.type == "furnace" then
          furnaces[#furnaces + 1] = {x = f.entity.position.x, y = f.entity.position.y}
        end
      end
    end
    if #furnaces == 0 then return "satisfied", "no furnaces to connect yet" end

    local fcx, fcy = (fz.x0 + fz.x1) / 2, (fz.y0 + fz.y1) / 2 -- the machines, not the power line
    table.sort(furnaces, function(a, b)
      return (a.x - fcx) ^ 2 + (a.y - fcy) ^ 2 < (b.x - fcx) ^ 2 + (b.y - fcy) ^ 2
    end)

    -- phase row ------------------------------------------------------------------------------
    if not sup then
      local entries, start, flow, row = plan_row(ctx, fz, item, furnaces[1], source)
      if not entries then return "blocked", "cannot connect the factory: " .. start end
      local all = copy_entries(fz.entries)
      for _, e in ipairs(entries) do all[#all + 1] = e end
      local x0, y0, x1, y1 = geometry.bbox_of(all, 0)
      fz.box = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
      zones.set_entries(player, fz, all)
      fz.supply = {phase = "route", item = item, start = start, flow = flow, next_furnace = 1, routed = {}, served = #row}
      debug.say(player, string.format("factory_supply: input belt + %d inserters planned on the factory", #row))
      return "working", "planned the input belt of the factory"
    end

    -- phases that wait for ghosts ------------------------------------------------------------
    local sz = zones.list(idx, SUPPLY_PURPOSE)[1]
    if sup.zone then sz = zones.get(idx, sup.zone) end

    -- phase route ----------------------------------------------------------------------------
    if sup.phase == "route" then
      if sup.next_furnace > #furnaces then
        if #sup.routed == 0 then return "blocked", "no belt path from the furnaces to the factory" end
        sup.phase = "belts"
        return "working", string.format("%d furnace line(s) planned", #sup.routed)
      end

      local env = make_env(ctx, fz, sz, source)
      local goals, goal_map, samples = make_goals(sup, sz)

      if not sup.search then
        local f = furnaces[sup.next_furnace]
        local spot = furnace_spot(env, f, sup.start)
        if not spot then
          sup.next_furnace = sup.next_furnace + 1 -- no room for an inserter at this furnace
          return "working", "no free spot for an inserter at a furnace, skipping it"
        end
        sup.search = {
          spot = spot, start = {tx = spot.tx, ty = spot.ty}, g = {}, parent = {}, heap = {}, closed = {},
          expansions = 0,
        }
      end
      local search = sup.search
      search.samples = samples

      local result, path, last = run_search(env, search, goals, goal_map)
      if result == "running" then
        return "working", string.format("looking for a belt path from furnace %d (%d tiles searched)",
          sup.next_furnace, search.expansions)
      end
      local spot = search.spot
      sup.search = nil
      sup.next_furnace = sup.next_furnace + 1
      if result == "failed" then
        debug.say(player, "factory_supply: no belt path from furnace " .. (sup.next_furnace - 1))
        return "working", "no belt path from furnace " .. (sup.next_furnace - 1) .. ", skipping it"
      end

      -- belts along the path; the last one points at the goal tile
      local entries = sz and copy_entries(sz.entries) or {}
      for i, k in ipairs(path) do
        local tx, ty = split_key(k)
        local nx, ny
        if i < #path then nx, ny = split_key(path[i + 1]) else nx, ny = tx + last.x, ty + last.y end
        entries[#entries + 1] = {
          name = BELT, x = tx + 0.5, y = ty + 0.5, direction = geometry.vec_to_dir(nx - tx, ny - ty),
        }
      end
      sup.routed[#sup.routed + 1] = {ins = spot.ins, o = spot.o}
      if sz then
        zones.set_entries(player, sz, entries)
      else
        local s = sup.start
        sz = zones.create(player, SUPPLY_PURPOSE, ctx.surface, entries, {
          margin = 0, box = {x0 = s.tx, y0 = s.ty, x1 = s.tx + 1, y1 = s.ty + 1}, permanent = true,
        })
        sup.zone = SUPPLY_PURPOSE
      end
      debug.say(player, string.format("factory_supply: belt path of %d tiles planned (furnace %d)", #path, #sup.routed))
      return "working", string.format("planned a belt path of %d tiles", #path)
    end

    if not sz then return "blocked", "the belt zone is missing" end

    -- phase belts: the line is built before any plate leaves a furnace ------------------------
    if sup.phase == "belts" then
      local status, note = wait_for_zone(ctx, sz, "belt line")
      if status then return status, note end
      local entries = copy_entries(sz.entries)
      for _, r in ipairs(sup.routed) do
        entries[#entries + 1] = {
          name = BURNER_INSERTER, x = r.ins.x, y = r.ins.y, direction = geometry.vec_to_dir(-r.o.x, -r.o.y),
          drop = {x = r.ins.x + r.o.x, y = r.ins.y + r.o.y},
        }
      end
      zones.set_entries(player, sz, entries)
      sup.phase = "inserters"
      return "working", "the belt line stands: adding the inserters at the furnaces"
    end

    -- phase inserters ------------------------------------------------------------------------
    if sup.phase == "inserters" then
      local status, note, found_sz = wait_for_zone(ctx, sz, "furnace inserter")
      if status then return status, note end
      fix_inserters(sz, found_sz)

      -- the plates arrive by belt now: the machines no longer take `item` by hand
      for _, e in ipairs(fz.entries) do
        if e.recipe and e.hand then
          local keep = {}
          for _, h in ipairs(e.hand) do
            if h ~= item then keep[#keep + 1] = h end
          end
          e.hand = keep
        end
      end
      sup.phase = "done"
      debug.say(player, "factory_supply: furnaces connected to the factory")
      return "satisfied", "the furnaces feed the factory"
    end

    return "satisfied", "factory_supply: " .. tostring(sup.phase)
  end,
}
