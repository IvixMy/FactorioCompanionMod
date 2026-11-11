-- Blueprints assigned to complex Companion actions.
-- A blueprint is stored as an export string (so it survives the original being deleted)
-- together with its footprint, and can be "stamped" repeatedly as ghosts.

local zones = require("scripts.zones")

local M = {}

local MIN_COVERAGE = 0.25 -- a stamp needs ore under at least 25% of its footprint
local MAX_STAMPS   = 300

local function ensure()
  storage.action_bps = storage.action_bps or {} -- [player_index][action_id] = {str, label, w, h}
end

function M.init() ensure() end

function M.get(idx, action)
  ensure()
  local t = storage.action_bps[idx]
  return t and t[action]
end

function M.clear(idx, action)
  ensure()
  local t = storage.action_bps[idx]
  if t then t[action] = nil end
end

function M.describe(bp)
  if not bp then return "Blueprint: none assigned" end
  return string.format("Blueprint: %s (%dx%d tiles)", bp.label, bp.w, bp.h)
end

-- Size in tiles of everything the blueprint places
local function footprint(stack)
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  local function grow(x, y, hs)
    minx = math.min(minx, x - hs)
    miny = math.min(miny, y - hs)
    maxx = math.max(maxx, x + hs)
    maxy = math.max(maxy, y + hs)
  end
  for _, e in pairs(stack.get_blueprint_entities() or {}) do
    local hs = 0.5
    local proto = prototypes.entity[e.name]
    if proto then
      local cb = proto.collision_box
      local half = math.max(math.abs(cb.left_top.x), math.abs(cb.left_top.y),
                            math.abs(cb.right_bottom.x), math.abs(cb.right_bottom.y))
      hs = math.max(0.5, math.ceil(half * 2) / 2)
    end
    grow(e.position.x, e.position.y, hs)
  end
  for _, t in pairs(stack.get_blueprint_tiles() or {}) do
    grow(t.position.x, t.position.y, 0.5)
  end
  if minx == math.huge then return nil end
  return math.max(1, math.ceil(maxx - minx)), math.max(1, math.ceil(maxy - miny))
end

-- The single blueprint inside a stack: the stack itself, or the active (else first) blueprint of a book.
local function pick_blueprint(stack, depth)
  depth = depth or 0
  if not (stack and stack.valid_for_read) then return nil end
  if stack.is_blueprint then return stack end
  if stack.is_blueprint_book and depth < 4 then
    local inv = stack.get_inventory(defines.inventory.item_main)
    if not inv then return nil end
    local active = stack.active_index and inv[stack.active_index]
    local found = active and pick_blueprint(active, depth + 1)
    if found then return found end
    for i = 1, #inv do
      found = pick_blueprint(inv[i], depth + 1)
      if found then return found end
    end
  end
  return nil
end

-- Everything the rest of the mod needs to know about a blueprint, read from a stack.
-- Returns the record {str, label, w, h, n (entities), poles, items = {[item] = count}} or nil + error text.
function M.from_stack(stack)
  local single = pick_blueprint(stack)
  if not single then return nil, "that is not a blueprint (or a book with one in it)." end
  if not single.is_blueprint_setup() then return nil, "that blueprint is empty." end
  local w, h = footprint(single)
  if not w then return nil, "that blueprint is empty." end

  local n, poles, items = 0, 0, {}
  for _, e in pairs(single.get_blueprint_entities() or {}) do
    n = n + 1
    local proto = prototypes.entity[e.name]
    if proto then
      if proto.type == "electric-pole" then poles = poles + 1 end
      local item = proto.items_to_place_this and proto.items_to_place_this[1]
      if item then items[item.name] = (items[item.name] or 0) + (item.count or 1) end
    end
  end
  return {str = single.export_stack(), label = single.label or "unnamed", w = w, h = h,
          n = n, poles = poles, items = items}
end

-- Items of the blueprint whose recipe exists but is not unlocked yet (sorted names).
function M.locked_items(bp, force)
  local out = {}
  for item in pairs(bp.items or {}) do
    local recipe = force.recipes[item]
    if recipe and not recipe.enabled then out[#out + 1] = item end
  end
  table.sort(out)
  return out
end

-- Blueprint (or book) text pasted by the player -> record, or nil + error text.
function M.from_string(text)
  text = (text or ""):gsub("%s+", "")
  if text == "" then return nil, "paste a blueprint string first." end
  local inv = game.create_inventory(1)
  local ok, result = pcall(function() return inv[1].import_stack(text) end)
  local bp, err
  if ok and result ~= nil and result <= 0 then
    bp, err = M.from_stack(inv[1])
  else
    err = "that text is not a valid blueprint string (was it copied completely?)."
  end
  inv.destroy()
  return bp, err
end

-- The blueprint (or active blueprint of the book) held in the player's cursor.
function M.from_cursor(player)
  local stack = player.cursor_stack
  if not (stack and stack.valid_for_read) then
    return nil, "hold a blueprint in your cursor first."
  end
  return M.from_stack(stack)
end

-- Returns the stored blueprint, or nil + an error message.
function M.assign_from_cursor(player, action)
  ensure()
  local bp, err = M.from_cursor(player)
  if not bp then return nil, err end
  storage.action_bps[player.index] = storage.action_bps[player.index] or {}
  storage.action_bps[player.index][action] = bp
  return bp
end

local function area_is_free(surface, force, area)
  for _, e in pairs(surface.find_entities_filtered{area = area, force = force}) do
    if e.type ~= "character" then return false end -- buildings or ghosts already there
  end
  return true
end

-- Grid of stamp positions covering the patch, nearest to the patch centre first.
function M.plan_stamps(surface, force, bp, ore, patch, player_index)
  local w, h = bp.w, bp.h
  local x0, y0 = math.floor(patch.x0), math.floor(patch.y0)
  local cols = math.ceil((patch.x1 - x0) / w)
  local rows = math.ceil((patch.y1 - y0) / h)
  local min_ore = math.max(1, math.floor(MIN_COVERAGE * w * h))

  local stamps = {}
  for ry = 0, rows - 1 do
    for cx = 0, cols - 1 do
      local ax = x0 + (cx + 0.5) * w
      local ay = y0 + (ry + 0.5) * h
      local area = {{ax - w / 2, ay - h / 2}, {ax + w / 2, ay + h / 2}}
      if surface.count_entities_filtered{area = area, name = ore} >= min_ore
         and area_is_free(surface, force, area)
         and not (player_index and zones.area_overlaps_zone(player_index, surface.index, area)) then -- never over a zone
        stamps[#stamps + 1] = {x = ax, y = ay, d = (ax - patch.x) ^ 2 + (ay - patch.y) ^ 2}
      end
    end
  end
  table.sort(stamps, function(a, b) return a.d < b.d end)
  while #stamps > MAX_STAMPS do stamps[#stamps] = nil end
  return stamps
end

-- Place the blueprint as ghosts at `pos`. Returns how many ghosts were created.
function M.stamp(surface, force, bp, pos)
  local inv = game.create_inventory(1)
  local stack = inv[1]
  local count = 0
  if stack.import_stack(bp.str) <= 0 and stack.valid_for_read and stack.is_blueprint_setup() then
    local ghosts = stack.build_blueprint{
      surface = surface, force = force, position = pos,
      direction = defines.direction.north,
      build_mode = defines.build_mode.normal,
      raise_built = true,
    }
    count = ghosts and #ghosts or 0
  end
  inv.destroy()
  return count
end

-- Places the blueprint as ghosts with its centre at `pos`, turned to `direction` (default north).
-- Returns the list of ghosts that were really created (entity ghosts and tile ghosts).
-- Nothing is raised: this is also used for trial placements that are rolled back.
function M.stamp_ghosts(surface, force, bp, pos, direction)
  local inv = game.create_inventory(1)
  local stack = inv[1]
  local out = {}
  if stack.import_stack(bp.str) <= 0 and stack.valid_for_read and stack.is_blueprint_setup() then
    local ok, ghosts = pcall(function()
      return stack.build_blueprint{
        surface = surface, force = force, position = pos,
        direction = direction or defines.direction.north,
        build_mode = defines.build_mode.normal,
        raise_built = false,
      }
    end)
    if ok and ghosts then
      for _, g in pairs(ghosts) do
        if g.valid then out[#out + 1] = g end
      end
    end
  end
  inv.destroy()
  return out
end

-- Entity ghosts as zone entries {name, x, y, direction, recipe?}; tile ghosts are skipped.
function M.ghost_entries(ghosts)
  local entries = {}
  for _, g in ipairs(ghosts) do
    if g.valid and g.type == "entity-ghost" then
      local e = {name = g.ghost_name, x = g.position.x, y = g.position.y, direction = g.direction}
      local ok, r = pcall(function() return g.get_recipe() end)
      if ok and r then e.recipe = type(r) == "string" and r or r.name end
      entries[#entries + 1] = e
    end
  end
  return entries
end

-- Puts back what is missing of a blueprint zone (it remembers its blueprint, place and turn):
-- the blueprint is placed again over the same spot. Entities that stand are left alone.
function M.restamp(zone, surface, force)
  if not (zone.bp_str and zone.bp_pos) then return 0 end
  return #M.stamp_ghosts(surface, force, {str = zone.bp_str}, zone.bp_pos, zone.bp_dir)
end

zones.restamper = M.restamp

return M
