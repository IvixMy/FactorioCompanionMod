-- Hand-crafting for the Companion companion.
--
-- resolve():  works out whether an item can be made from a pool of materials (recursively
--             through intermediates, hand-craftable recipes only) and what that costs.
-- enqueue():  takes the raw materials out of the companion's inventory and starts a timed job.
-- tick():     advances the queue in the background, so the companion keeps doing other things.
--
-- Jobs are plain tables stored in data.craft_queue; data.pending[item] counts items that
-- queued jobs will deliver, so the planner doesn't order the same thing twice.

local goals = require("scripts.goals")
local vehicles = require("scripts.vehicles")

local M = {}

local MAX_DEPTH = 6
local FALLBACK_CATEGORIES = {["crafting"] = true, ["basic-crafting"] = true, ["advanced-crafting"] = true}

local function categories(entity_name)
  local proto = prototypes.entity[entity_name]
  return (proto and proto.crafting_categories) or FALLBACK_CATEGORIES
end

local function product_amount(p)
  if p.amount then return p.amount end
  return math.max(1, math.floor(((p.amount_min or 1) + (p.amount_max or 1)) / 2))
end

-- Property reads on prototype userdata throw when the property does not exist in the running
-- Factorio version (e.g. `category` was replaced by `categories` in 2.1). Read through pcall.
local function try_get(obj, key)
  local ok, value = pcall(function() return obj[key] end)
  if ok then return value end
  return nil
end

-- True if any category of the recipe is one the crafter can handle.
local function has_usable_category(proto, cats)
  local list = try_get(proto, "categories") -- Factorio 2.1+
  if list then
    for _, cat in pairs(list) do
      if cats[cat] then return true end
    end
    return false
  end
  local cat = try_get(proto, "category") -- Factorio 2.0
  return cat ~= nil and cats[cat] == true
end

local function hand_craftable(proto)
  if proto.hidden then return false end
  -- 2.1 name, then the 2.0 name
  local hidden = try_get(proto, "hidden_from_player_crafting")
  if hidden == nil then hidden = try_get(proto, "hide_from_player_crafting") end
  return not hidden
end

-- Cheapest sensible hand-craftable, researched recipe that produces `item`.
local function pick_recipe(force, item, cats)
  local candidates = {}
  local filter = {{filter = "has-product-item", elem_filters = {{filter = "name", name = item}}}}
  for name, proto in pairs(prototypes.get_recipe_filtered(filter)) do
    local r = force.recipes[name]
    if r and r.enabled and hand_craftable(proto) and has_usable_category(proto, cats) then
      local loops = false
      for _, ing in ipairs(proto.ingredients) do
        if ing.name == item then loops = true end
      end
      if not loops then candidates[#candidates + 1] = proto end
    end
  end
  if #candidates == 0 then return nil end
  table.sort(candidates, function(a, b)
    local am, bm = (a.name == item), (b.name == item)
    if am ~= bm then return am end
    return a.name < b.name
  end)
  return candidates[1]
end

local function expand(force, cats, item, count, stock, acc, depth)
  local avail = stock[item] or 0
  local use = math.min(avail, count)
  if use > 0 then
    stock[item] = avail - use
    acc.raw[item] = (acc.raw[item] or 0) + use
  end
  local missing = count - use
  if missing <= 0 then return true end
  if depth >= MAX_DEPTH then return false end

  local recipe = pick_recipe(force, item, cats)
  if not recipe then return false end
  local per = 0
  for _, p in ipairs(recipe.products) do
    if p.type == "item" and p.name == item then per = per + product_amount(p) end
  end
  if per <= 0 then return false end

  local times = math.ceil(missing / per)
  acc.time = acc.time + recipe.energy * times
  for _, ing in ipairs(recipe.ingredients) do
    if ing.type ~= "item" then return false end -- fluids can't be hand-crafted
    if not expand(force, cats, ing.name, ing.amount * times, stock, acc, depth + 1) then return false end
  end
  for _, p in ipairs(recipe.products) do
    if p.type == "item" then acc.out[p.name] = (acc.out[p.name] or 0) + product_amount(p) * times end
  end
  return true
end

-- stock: {item -> count} of materials that may be used (it is modified).
-- Returns {raw = {item->n taken from stock}, out = {item->n produced}, time = seconds} or nil.
function M.resolve(entity_name, force, item, count, stock)
  stock[item] = 0 -- never "use" the thing we are trying to make
  local acc = {raw = {}, out = {}, time = 0}
  if expand(force, categories(entity_name), item, count, stock, acc, 0) then return acc end
  return nil
end

function M.inventory_counts(inv)
  local t = {}
  for _, s in pairs(inv.get_contents()) do
    if s.quality == "normal" then t[s.name] = (t[s.name] or 0) + s.count end
  end
  return t
end

function M.copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- Start a job: remove the raw materials now, deliver the products later.
function M.enqueue(data, inv, plan, target, speed)
  data.craft_queue = data.craft_queue or {}
  data.pending = data.pending or {}
  for item, n in pairs(plan.raw) do
    inv.remove{name = item, count = n, quality = "normal"}
  end
  local ticks = math.max(1, math.ceil(plan.time * 60 / speed))
  local produced = plan.out[target] or 0
  data.craft_queue[#data.craft_queue + 1] = {
    target = target, out = plan.out, ticks = ticks, remaining = ticks, produced = produced,
  }
  data.pending[target] = (data.pending[target] or 0) + produced
end

function M.tick(data)
  vehicles.watchdog(data) -- never keeps driving once nothing asks to walk any more
  local queue = data.craft_queue
  if not queue or #queue == 0 then return end
  local job = queue[1]
  job.remaining = job.remaining - 1
  if job.remaining > 0 then return end

  local c = data.entity
  local inv = c.get_main_inventory()
  for item, n in pairs(job.out) do
    local inserted = inv.insert{name = item, count = n, quality = "normal"}
    if inserted < n then
      c.surface.spill_item_stack{position = c.position, stack = {name = item, count = n - inserted}, enable_looted = false}
    end
  end
  data.pending = data.pending or {}
  data.pending[job.target] = math.max(0, (data.pending[job.target] or 0) - job.produced)
  table.remove(queue, 1)
  -- the game never saw this craft: tell the goals system (technology triggers "craft X", ...)
  for item, n in pairs(job.out) do goals.notify(c.force, "craft", item, n) end
  data.status = "Finished crafting " .. job.target
end

function M.status(data)
  local queue = data.craft_queue
  if not queue or #queue == 0 then return nil end
  local job = queue[1]
  local pct = math.floor(100 * (1 - job.remaining / job.ticks))
  return string.format("%s (%d%%), %d job(s) queued", job.target, pct, #queue)
end

return M
