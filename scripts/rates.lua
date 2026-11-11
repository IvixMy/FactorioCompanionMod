-- Rate calculator: inputs / outputs per second of the machines of a building zone.
--
-- Same idea (and the same formulas) as the "Rate Calculator" mod (raiguard): select an area, get what
-- the machines in it consume and produce per second. That mod cannot be called from another mod
-- (it has no remote interface, only a selection tool + GUI, and keeps its maths private), so the
-- companion carries the part it needs:
--
--   * crafters (assembling machines, furnaces): ingredients / products per second from the recipe,
--     the machine's crafting speed and its productivity bonus   (calc-util.process_crafter)
--   * laboratories: science packs consumed per second for a research, from the lab's researching
--     speed, its speed bonus and the research unit time       (calc-util.process_lab)
--
-- Machines that are only PLANNED (not built yet) are counted with the prototype's base stats, so a
-- factory can be sized before it stands.
--
--   rates.zone(zone, force)                        -> {[item] = {input = n, output = n, machines = n}}
--   rates.production(player_index, force, purpose) -> {[item] = output per second} over a zone family
--   rates.lab_consumption(force, tech, lab_entity) -> {[pack] = packs per second ONE lab uses}
--   rates.labs_needed(production, consumption)     -> labs that use up everything made, or nil
--   rates.pick_tech(force, preferred_name)         -> the technology the labs are (or will be) working on

local zones = require("scripts.zones")
local research = require("scripts.research")

local M = {}

local function try_get(obj, key)
  local ok, value = pcall(function() return obj[key] end)
  if ok then return value end
  return nil
end

-- Calls a prototype method that may be a plain attribute in other Factorio versions.
local function proto_number(proto, method, attribute, fallback)
  local ok, v = pcall(function() return proto[method]("normal") end)
  if ok and type(v) == "number" then return v end
  ok, v = pcall(function() return proto[method]() end)
  if ok and type(v) == "number" then return v end
  v = try_get(proto, attribute)
  if type(v) == "number" then return v end
  return fallback
end

local function product_amount(p)
  local amount = p.amount
  if not amount then amount = ((p.amount_min or 1) + (p.amount_max or 1)) / 2 end
  return amount * (p.probability or 1)
end

local function add(out, item, field, amount)
  local r = out[item]
  if not r then
    r = {input = 0, output = 0, machines = 0}
    out[item] = r
  end
  r[field] = r[field] + amount
end

---------------------------------------------------------------------
-- Crafters
---------------------------------------------------------------------

-- Adds the rates of one crafter. `entity` may be nil (planned): base prototype stats are used.
local function add_crafter(out, force, entry, entity)
  local recipe = force.recipes[entry.recipe or ""]
  if not recipe then return end

  local speed, bonus = 1, 0
  if entity and entity.valid then
    speed = entity.crafting_speed
    bonus = entity.productivity_bonus or 0
  else
    local proto = prototypes.entity[entry.name]
    if proto then speed = proto_number(proto, "get_crafting_speed", "crafting_speed", 1) end
  end
  if speed <= 0 then return end

  local duration = recipe.energy / speed
  for _, ing in ipairs(recipe.ingredients) do
    add(out, ing.name, "input", ing.amount / duration)
    out[ing.name].machines = out[ing.name].machines + 1
  end
  local productivity = 1 + math.min(bonus + (try_get(recipe, "productivity_bonus") or 0),
    try_get(recipe.prototype, "maximum_productivity") or 3)
  for _, product in ipairs(recipe.products) do
    if product.type ~= "research-progress" then
      local base = product_amount(product)
      local ignored = math.min(base, product.ignored_by_productivity or 0)
      add(out, product.name, "output", (ignored + (base - ignored) * productivity) / duration)
      out[product.name].machines = out[product.name].machines + 1
    end
  end
end

-- Inputs and outputs per second of every machine with a recipe in the zone.
function M.zone(zone, force)
  local out = {}
  local found = zones.index_entities(zone, force)
  for _, entry in ipairs(zone.entries or {}) do
    if entry.recipe then
      local f = found[zones.key(entry.name, {x = entry.x, y = entry.y})]
      add_crafter(out, force, entry, f and not f.ghost and f.entity.valid and f.entity or nil)
    end
  end
  return out
end

-- What a whole zone family (e.g. "science_factory") makes: {[item] = output per second}.
function M.production(player_index, force, purpose)
  local total = {}
  for _, zone in ipairs(zones.list(player_index, purpose)) do
    for item, r in pairs(M.zone(zone, force)) do
      if r.output > 0 then total[item] = (total[item] or 0) + r.output end
    end
  end
  return total
end

---------------------------------------------------------------------
-- Laboratories
---------------------------------------------------------------------

-- The technology the labs work on: the current research; else `preferred` (a name) when it can
-- still be researched; else the one the progress tracker picks next.
function M.pick_tech(force, preferred)
  local current = force.current_research
  if current then return current end
  local tech = preferred and force.technologies[preferred]
  if tech and not tech.researched then return tech end
  return research.progress(force).next
end

-- Packs per second that ONE lab uses for `tech`. `lab` is a built lab (or nil: base stats + the
-- force's lab speed bonus).
function M.lab_consumption(force, tech, lab)
  local out = {}
  if not tech then return out end
  local proto = lab and lab.valid and lab.prototype or prototypes.entity["lab"]
  if not proto then return out end

  local drain = (try_get(proto, "science_pack_drain_rate_percent") or 100) / 100
  local researching = proto_number(proto, "get_researching_speed", "researching_speed", 1)
  local bonus = (lab and lab.valid and lab.speed_bonus) or force.laboratory_speed_modifier or 0
  local unit_seconds = (tech.research_unit_energy or 60) / 60

  local per_unit = researching * (1 + bonus) * drain / unit_seconds
  for _, ing in ipairs(tech.research_unit_ingredients) do
    out[ing.name] = (ing.amount or 1) * per_unit
  end
  return out
end

-- Labs needed to use up all the packs that are made. Only packs somebody makes count (a pack that
-- is hand-fed is not part of the calculation); with several packs the scarcest one decides, because
-- a lab that lacks one pack stands still. nil when none of the packs is made.
function M.labs_needed(production, consumption)
  local best
  for pack, per_lab in pairs(consumption) do
    local made = production[pack]
    if made and made > 0 and per_lab > 0 then
      local n = made / per_lab
      if not best or n < best then best = n end
    end
  end
  return best and math.max(1, math.ceil(best - 1e-6)) or nil
end

return M
