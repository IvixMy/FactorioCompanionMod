-- Index of what the force's chests and logistic networks contain on a surface (cached for a few seconds).
--
--   * plain chests ("container")                    -> scanned one by one
--   * logistic chests that belong to a network      -> counted through the network (get_contents), so requester
--                                                      chests are never raided and items "in flight" are ignored
--   * logistic chests outside any network           -> scanned like plain chests
-- find_chest() still returns a CHEST the companion can walk to: for network items it asks the network for its
-- best pickup point (select_pickup_point) and uses that point's owner.

local common = require("scripts.common")

local M = {}

function M.invalidate()
  storage.supply = {}
end

local function surface_networks(force, surface)
  if not common.USE_LOGISTIC_NETWORK then return {} end
  local all = common.try_get(force, "logistic_networks") -- {[surface name] = {LuaLogisticNetwork...}}
  local list = all and all[surface.name]
  return list or {}
end

local function chest_network(chest)
  if chest.type ~= "logistic-container" then return nil end
  return common.try_get(chest, "logistic_network")
end

local function is_requester(chest)
  if chest.type ~= "logistic-container" then return false end
  local proto = chest.prototype
  local mode = common.try_get(proto, "logistic_mode")
  return mode == "requester"
end

local function add(index, totals, chest_or_net, name, quality, count, key_list)
  local k = name .. "|" .. quality
  local list = index[k]
  if not list then
    list = {}
    index[k] = list
  end
  list[#list + 1] = chest_or_net
  if quality == "normal" then totals[name] = (totals[name] or 0) + count end
end

function M.get(force, surface)
  local key = force.index .. ":" .. surface.index
  local s = storage.supply[key]
  if s and game.tick - s.tick <= common.SUPPLY_REFRESH then return s end

  local index, totals, net_index = {}, {}, {}

  local chests = surface.find_entities_filtered{type = common.CHEST_TYPES, force = force}
  for _, chest in pairs(chests) do
    local skip = common.USE_LOGISTIC_NETWORK and (chest_network(chest) ~= nil or is_requester(chest))
    if not skip then
      local inv = chest.get_inventory(defines.inventory.chest)
      if inv and not inv.is_empty() then
        for _, stack in pairs(inv.get_contents()) do
          add(index, totals, chest, stack.name, stack.quality, stack.count)
        end
      end
    end
  end

  for _, net in pairs(surface_networks(force, surface)) do
    local ok, contents = pcall(net.get_contents)
    if ok and contents then
      for _, stack in pairs(contents) do
        local quality = stack.quality or "normal"
        if type(quality) ~= "string" then quality = quality.name end
        add(net_index, totals, net, stack.name, quality, stack.count)
      end
    end
  end

  s = {tick = game.tick, index = index, net_index = net_index, totals = totals}
  storage.supply[key] = s
  return s
end

local function consider(chest, name, quality, need, from, st)
  if not (chest and chest.valid) then return end
  local have = chest.get_item_count{name = name, quality = quality}
  if have <= 0 then return end
  local d = common.dist2(chest.position, from)
  if have >= need then
    if not st.best or d < st.best_d then st.best, st.best_d = chest, d end
  else
    if not st.partial or d < st.partial_d then st.partial, st.partial_d = chest, d end
  end
end

-- Closest chest holding `need` of the item; failing that, the closest holding some.
-- skip (optional): set {[unit_number] = true} of chests that must not be used (e.g. the lab feed chest).
function M.find_chest(force, surface, name, quality, need, from, skip)
  quality = quality or "normal"
  local supply = M.get(force, surface)
  local st = {}

  for _, chest in pairs(supply.index[name .. "|" .. quality] or {}) do
    if chest.valid and not (skip and skip[chest.unit_number]) then
      consider(chest, name, quality, need, from, st)
    end
  end

  for _, net in pairs(supply.net_index[name .. "|" .. quality] or {}) do
    if net.valid then
      local ok, point = pcall(net.select_pickup_point, {
        name = name, quality = quality, position = from, include_buffers = true,
      })
      local owner = ok and point and point.owner
      if owner and owner.valid and (owner.type == "container" or owner.type == "logistic-container")
         and not (skip and skip[owner.unit_number]) then
        consider(owner, name, quality, need, from, st)
      end
    end
  end

  return st.best or st.partial
end

return M
