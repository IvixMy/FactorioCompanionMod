-- Fuel logistics for ANY burner entity: boilers, burner drills, stone furnaces, heaters, vehicles...
--
-- Everything is derived from the entity itself (its fuel categories, fuel slots, power draw), so
-- nothing here knows about a specific machine. The flow is always the same:
--
--   needs_fuel(entity)            is it (nearly) out of energy?
--   plan(player, data, entity)    what is the BEST fuel I can get, and where from?
--   refuel(player, data, entity)  start the tasks that deliver it
--   tend(player, data, list)      refuel whichever entity of the list is closest to running dry
--
-- "Best" = the fuel with the highest energy per item that the entity accepts and that is
-- obtainable right now, from (in this order for the same fuel): the companion's inventory,
-- a chest, or by hand from something nearby - an ore patch (coal) or trees (wood).
-- The plan is recomputed from the world on every call, so an interrupted job just resumes.

local common = require("scripts.common")
local supply = require("scripts.supply")
local tasks  = require("scripts.tasks")
local ore    = require("scripts.ore")

local M = {}

M.RESERVE_SECONDS = 45     -- refuel when less than this much running time is left
M.BUFFER_SECONDS  = 600    -- ...and load enough for this much running time (fewer refuelling trips)
M.MIN_FUEL_VALUE  = 1e6    -- ignore fuels below 1 MJ (spoilage, seeds...)
M.MAX_FUEL_VALUE  = 50e6   -- ...and precious ones above 50 MJ (rocket / nuclear fuel)
M.DEFAULT_WATTS   = 150e3  -- used when the entity's power draw can't be read
M.GATHER_MAX      = 100    -- never hand-mine more than this in one trip
M.STOCK_KEEP      = 5      -- items left behind in a stocked drill (it needs them to keep running)
M.MAX_GROUP       = 6      -- refuel up to this many machines in one round
M.GROUP_RANGE     = 50     -- ...that are within this many tiles of the neediest one
M.GATHER_RADII    = {80, 150, 200} -- how far (tiles) to look for coal / trees to mine by hand, nearest first
M.CHARTED_RADIUS  = 500            -- ...and if none: how far to look on the map the player has charted

---------------------------------------------------------------------
-- Prototype catalogue (built lazily, identical on every machine)
---------------------------------------------------------------------

local catalogue

local function add(map, key, value)
  local list = map[key]
  if not list then
    list = {}
    map[key] = list
  end
  list[#list + 1] = value
end

local function products_of(proto)
  local props = common.try_get(proto, "mineable_properties")
  if props and props.minable and props.products then return props.products end
  return {}
end

local function build_catalogue()
  local fuels = {}
  for name, proto in pairs(prototypes.item) do
    local value = common.try_get(proto, "fuel_value") or 0
    local category = common.try_get(proto, "fuel_category")
    if value > 0 and not common.try_get(proto, "hidden") then
      category = category or "chemical" -- property unreadable in this game version: assume the usual one
      fuels[name] = {name = name, value = value, category = category, stack = proto.stack_size}
    end
  end

  -- fuel item -> names of the resource entities that yield it (coal -> {"coal"})
  local from_resource, from_tree = {}, {}
  for name, proto in pairs(prototypes.get_entity_filtered{{filter = "type", type = "resource"}}) do
    for _, p in ipairs(products_of(proto)) do
      if p.type == "item" and fuels[p.name] then add(from_resource, p.name, name) end
    end
  end
  -- fuel items that trees drop (wood)
  for _, proto in pairs(prototypes.get_entity_filtered{{filter = "type", type = "tree"}}) do
    for _, p in ipairs(products_of(proto)) do
      if p.type == "item" and fuels[p.name] then from_tree[p.name] = true end
    end
  end
  for _, names in pairs(from_resource) do table.sort(names) end
  return {fuels = fuels, from_resource = from_resource, from_tree = from_tree}
end

local function catalogue_get()
  if not catalogue then catalogue = build_catalogue() end
  return catalogue
end

---------------------------------------------------------------------
-- Reading an entity
---------------------------------------------------------------------

function M.is_burner(entity)
  if not (entity and entity.valid) then return false end
  local ok, inv = pcall(function() return entity.get_fuel_inventory() end)
  return ok and inv ~= nil
end

-- The fuel categories an entity burns, as a set {chemical = true, ...} (nil when unreadable).
local function fuel_categories(entity)
  local burner = common.try_get(entity, "burner")
  local cats = burner and common.try_get(burner, "fuel_categories")
  if not cats then
    local bp = common.try_get(entity.prototype, "burner_prototype")
    cats = bp and common.try_get(bp, "fuel_categories")
  end
  if type(cats) ~= "table" then return nil end
  local set = {}
  for k, v in pairs(cats) do
    if type(k) == "number" then set[v] = true else set[k] = true end -- list or dictionary
  end
  return set
end

-- Power draw in watts (max), with a sane fallback.
local function watts(entity)
  local proto = entity.prototype
  local per_tick
  local ok, v = pcall(function() return proto.get_max_energy_usage(entity.quality) end)
  if ok and type(v) == "number" then per_tick = v end
  if not per_tick then per_tick = common.try_get(proto, "max_energy_usage") end
  if type(per_tick) == "number" and per_tick > 0 then return per_tick * 60 end
  return M.DEFAULT_WATTS
end

-- Fuels the entity accepts, best (most energy per item) first.
-- opts.min_value / opts.max_value override the default energy window (J per item).
function M.candidates(entity, opts)
  opts = opts or {}
  local lo, hi = opts.min_value or M.MIN_FUEL_VALUE, opts.max_value or M.MAX_FUEL_VALUE
  local cats = fuel_categories(entity)
  local list = {}
  for _, f in pairs(catalogue_get().fuels) do
    if f.value >= lo and f.value <= hi and (cats == nil or cats[f.category]) then list[#list + 1] = f end
  end

  -- Fallback: ask the fuel slot itself which items it accepts (it filters by fuel category)
  if #list == 0 then
    local inv = entity.get_fuel_inventory()
    if inv then
      for _, f in pairs(catalogue_get().fuels) do
        if f.value >= lo and f.value <= hi then
          local ok, can = pcall(function() return inv.can_insert{name = f.name, count = 1} end)
          if ok and can then list[#list + 1] = f end
        end
      end
    end
  end

  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.name < b.name
  end)
  return list
end

-- Joules the entity can still burn (items in its fuel slots + the item currently burning).
function M.energy_left(entity)
  local inv = entity.get_fuel_inventory()
  if not inv then return nil end
  local fuels, total = catalogue_get().fuels, 0
  for _, s in pairs(inv.get_contents()) do
    local f = fuels[s.name]
    if f then total = total + f.value * s.count end
  end
  local burner = common.try_get(entity, "burner")
  total = total + (burner and common.try_get(burner, "remaining_burning_fuel") or 0)
  return total
end

function M.seconds_left(entity)
  local left = M.energy_left(entity)
  if not left then return math.huge end
  return left / watts(entity)
end

-- Energy that counts as "low": a few seconds of work, but never more than a quarter of what the
-- fuel slots can hold (otherwise a machine that burns fast could never be considered full).
local function reserve_joules(entity, opts)
  local inv = entity.get_fuel_inventory()
  local weakest
  for _, f in ipairs(M.candidates(entity, opts)) do weakest = f end -- last = lowest energy
  local capacity = weakest and (#inv * weakest.stack * weakest.value) or math.huge
  return math.min(watts(entity) * ((opts and opts.reserve_seconds) or M.RESERVE_SECONDS), 0.25 * capacity)
end

function M.needs_fuel(entity, opts)
  if not M.is_burner(entity) then return false end
  return M.energy_left(entity) < reserve_joules(entity, opts)
end

-- How many items of `fuel` to load for a BUFFER_SECONDS run.
function M.load_count(entity, fuel, opts)
  local seconds = (opts and opts.buffer_seconds) or M.BUFFER_SECONDS
  local n = math.ceil(watts(entity) * seconds / fuel.value)
  local room = #entity.get_fuel_inventory() * fuel.stack
  return math.max(2, math.min(n, room))
end

---------------------------------------------------------------------
-- Choosing the fuel
---------------------------------------------------------------------

-- Something the companion can mine by hand to get this fuel. Looks around `pos` in wider and
-- wider circles (M.GATHER_RADII). Returns {kind, names, radius} or nil.
local function find_gather(surface, force, fuel, pos, radii)
  local cat = catalogue_get()
  local names = cat.from_resource[fuel.name]
  for _, radius in ipairs(radii) do
    if names and ore.has(surface, names, pos, radius) then
      return {kind = "resource", names = names, radius = radius}
    end
    if cat.from_tree[fuel.name]
       and surface.count_entities_filtered{type = "tree", position = pos, radius = radius, limit = 1} > 0 then
      return {kind = "tree", radius = radius}
    end
  end
  -- nothing close: use the map the player has charted (scripts/ore.lua)
  if names then
    local far = ore.find_charted(surface, force, names, pos, M.CHARTED_RADIUS)
    if far then
      return {kind = "resource", names = names, radius = 48, near = {x = far.x, y = far.y}, distance = far.distance}
    end
  end
  return nil
end

---------------------------------------------------------------------
-- Extra fuel stocks (e.g. coal piling up in the coal drills)
---------------------------------------------------------------------

-- fn(player, data, item) -> list of {entity = LuaEntity, count = n}: fuel the companion may TAKE
-- from machines (n = how many items it may remove).
local stocks = {}
function M.register_stock(fn) stocks[#stocks + 1] = fn end

local function find_stock(player, data, item, from)
  local list, total = {}, 0
  for _, fn in ipairs(stocks) do
    for _, st in ipairs(fn(player, data, item) or {}) do
      if st.entity.valid and st.count > 0 then
        list[#list + 1] = st
        total = total + st.count
      end
    end
  end
  table.sort(list, function(a, b) return common.dist2(a.entity.position, from) < common.dist2(b.entity.position, from) end)
  return list, total
end

---------------------------------------------------------------------
-- Choosing the fuel (for a GROUP of machines that share one trip)
---------------------------------------------------------------------

local function accepts(entity, f)
  local cats = fuel_categories(entity)
  return cats == nil or cats[f.category] == true
end

-- The neediest entity first, then up to MAX_GROUP - 1 others (close by) that burn the same fuel.
local function group_for(entity, f, others)
  local group = {entity}
  for _, e in ipairs(others or {}) do
    if #group >= M.MAX_GROUP then break end
    if e ~= entity and e.valid and e.surface.index == entity.surface.index and accepts(e, f)
       and common.dist2(e.position, entity.position) <= M.GROUP_RANGE * M.GROUP_RANGE then
      group[#group + 1] = e
    end
  end
  return group
end

-- Best obtainable fuel for the entity (and the others in opts.group that need it too), or nil.
-- Returns {item, source = "carried" | "stock" | "chest" | "gather" | "partial", group, total,
--          available (items I will hold once the source step is done), stock, chest, take, gather}
function M.plan(player, data, entity, opts)
  opts = opts or {}
  local c = data.entity
  local surface, force = c.surface, player.force
  local cinv = c.get_main_inventory()
  local pos = entity.position
  local totals = supply.get(force, surface).totals
  local radii = opts.radius and {opts.radius} or M.GATHER_RADII
  local partial

  for _, f in ipairs(M.candidates(entity, opts)) do
    local group = group_for(entity, f, opts.group)
    local total = 0
    for _, e in ipairs(group) do total = total + M.load_count(e, f, opts) end
    local first_need = M.load_count(entity, f, opts)
    local carried = cinv.get_item_count(f.name)
    local base = {item = f.name, value = f.value, stack = f.stack, group = group, total = total, carried = carried}
    local function done(extra)
      for k, v in pairs(extra) do base[k] = v end
      return base
    end

    if carried >= total then
      return done{source = "carried", available = carried}
    end

    -- fuel piled up in machines (the coal drills): no walking to an ore patch needed
    local stock, stock_n = find_stock(player, data, f.name, pos)
    if stock_n > 0 and carried + stock_n >= first_need then
      return done{source = "stock", stock = stock, available = carried + math.min(stock_n, total - carried)}
    end

    if (totals[f.name] or 0) > 0 then
      local missing = math.max(1, total - carried)
      local chest = supply.find_chest(force, surface, f.name, "normal", missing, pos)
      if chest then
        local have = chest.get_item_count{name = f.name, quality = "normal"}
        local take = math.min(have, missing)
        return done{source = "chest", chest = chest, take = take, available = carried + take}
      end
    end

    local gather = find_gather(surface, force, f, pos, radii)
    if gather then
      local want = math.max(1, math.min(total - carried, M.GATHER_MAX))
      return done{source = "gather", gather = gather, want = want, available = carried + want}
    end

    if carried > 0 and not partial then
      partial = done{source = "partial", available = carried}
    end
  end
  return partial
end

-- Human-readable reason why no fuel could be found (shown in the status line / chat).
function M.explain(player, data, entity)
  local c = data.entity
  local surface, force = c.surface, player.force
  local cat = catalogue_get()
  local cands = M.candidates(entity)
  if #cands == 0 then
    local n, seen = 0, {}
    for _, f in pairs(cat.fuels) do
      n = n + 1
      seen[f.category] = true
    end
    local cats, mine = fuel_categories(entity), {}
    for k in pairs(cats or {}) do mine[#mine + 1] = tostring(k) end
    local known = {}
    for k in pairs(seen) do known[#known + 1] = k end
    table.sort(mine)
    table.sort(known)
    return string.format("accepts no fuel I know of | fuels known: %d (categories: %s) | %s burns: %s",
      n, table.concat(known, ","), entity.name, #mine > 0 and table.concat(mine, ",") or "unreadable")
  end

  local names, hints = {}, {}
  for _, f in ipairs(cands) do
    names[#names + 1] = f.name
    local res = cat.from_resource[f.name]
    if res then
      local far = ore.find_charted(surface, force, res, entity.position, 2 * M.CHARTED_RADIUS)
      hints[#hints + 1] = far
        and string.format("%s: nearest charted %s is %d tiles away (limit %d)",
            f.name, table.concat(res, "/"), math.floor(far.distance), M.CHARTED_RADIUS)
        or string.format("%s: no charted %s ore", f.name, table.concat(res, "/"))
    end
  end
  return string.format("accepts %s | %s", table.concat(names, ", "),
    #hints > 0 and table.concat(hints, " | ") or "none of them can be mined")
end

local SOURCE_TEXT = {
  carried = "from my inventory", chest = "from a chest", partial = "with what I carry",
  stock = "from the coal drills",
}

local function describe(plan)
  local how = SOURCE_TEXT[plan.source]
  if plan.source == "gather" then
    how = (plan.gather.kind == "tree") and "chopped from trees" or "mined from the nearby ore patch"
    if plan.gather.distance then
      how = string.format("mined from a charted patch %d tiles away", math.floor(plan.gather.distance))
    end
  end
  local who = plan.group[1].name
  if #plan.group > 1 then who = string.format("%s and %d more", who, #plan.group - 1) end
  return string.format("refuelling %s with %s (%s)", who, plan.item, how)
end

---------------------------------------------------------------------
-- Doing it
---------------------------------------------------------------------

-- Share `available` items between the machines so that they all run for about the same time
-- (a boiler burns far more than a furnace: a fixed amount each would starve all but one).
local function allocate(group, f, available, opts)
  local total_w = 0
  for _, e in ipairs(group) do total_w = total_w + watts(e) end
  local cap = (opts and opts.buffer_seconds) or M.BUFFER_SECONDS
  local seconds = math.min(cap, available * f.value / total_w)

  local out, left = {}, available
  for _, e in ipairs(group) do
    if left <= 0 then break end
    local room = #e.get_fuel_inventory() * f.stack
    local n = math.floor(watts(e) * seconds / f.value + 0.5)
    n = math.max(1, math.min(n, room, left))
    out[#out + 1] = {entity = e, count = n}
    left = left - n
  end
  return out
end

-- Start the task chain for a plan. The caller must make sure no task is running.
-- chain:  [get the fuel]  ->  insert into machine 1  ->  insert into machine 2  -> ...
function M.start(data, plan, opts)
  local f = {value = plan.value, stack = plan.stack}
  local share = allocate(plan.group, f, plan.available, opts)

  local nxt
  for i = #share, 1, -1 do
    nxt = tasks.new("transfer", {
      target = share[i].entity, mode = "insert", slot = "fuel", item = plan.item,
      count = share[i].count, then_task = nxt,
    })
  end

  if plan.source == "carried" or plan.source == "partial" then
    tasks.start(data, nxt)

  elseif plan.source == "stock" then
    local left = plan.available - plan.carried
    local takes = {}
    for _, st in ipairs(plan.stock) do
      if left <= 0 then break end
      local n = math.min(st.count, left)
      takes[#takes + 1] = {entity = st.entity, count = n}
      left = left - n
    end
    local chain = nxt
    for i = #takes, 1, -1 do
      chain = tasks.new("transfer", {
        target = takes[i].entity, mode = "take", item = plan.item, count = takes[i].count,
        keep = M.STOCK_KEEP, then_task = chain,
      })
    end
    tasks.start(data, chain)

  elseif plan.source == "chest" then
    tasks.start(data, tasks.new("fetch", {
      chest = plan.chest, item = plan.item, quality = "normal", count = plan.take,
      fetch = 1, fetch_max = plan.take, purpose = "fuel", then_task = nxt,
    }))

  else -- gather by hand, then deliver
    tasks.start(data, tasks.new("mine", {
      item = plan.item, target = plan.carried + plan.want,
      near = plan.gather.near or plan.group[1].position, radius = plan.gather.radius,
      resource = plan.gather.kind == "resource" and plan.gather.names or nil,
      from_trees = plan.gather.kind == "tree" or nil,
      then_task = nxt,
    }))
  end
  data.status = describe(plan)
end

-- Refuel one entity (plus the others in opts.group). Returns "working" | "blocked", note.
function M.refuel(player, data, entity, opts)
  if data.task then return "working", "waiting for the current task before refuelling" end
  local plan = M.plan(player, data, entity, opts)
  if not plan then
    return "blocked", string.format("%s needs fuel but I found none (%s)", entity.name, M.explain(player, data, entity))
  end
  M.start(data, plan, opts)
  return "working", describe(plan)
end

-- Every entity of `list` that needs fuel, the one closest to running dry first.
function M.needy(list, opts)
  local out = {}
  for _, e in ipairs(list) do
    if e.valid and M.needs_fuel(e, opts) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return M.seconds_left(a) < M.seconds_left(b) end)
  return out
end

-- The entity of `list` closest to running dry, among those that need fuel (or nil).
function M.neediest(list, opts)
  return M.needy(list, opts)[1]
end

-- Refuel whichever entities of `list` need it most. Returns nil when nothing needs fuel.
function M.tend(player, data, list, opts)
  local needy = M.needy(list, opts)
  if #needy == 0 then return nil end
  opts = opts or {}
  opts.group = needy
  return M.refuel(player, data, needy[1], opts)
end

return M
