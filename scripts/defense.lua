-- Defense: the Engineer shoots the enemy that is closest to YOU.
--
-- Switched on with the "Defend me" checkbox of the menu (per player, off by default). It works in the two
-- modes where the Engineer follows you (Follow only / Follow and build nearby ghosts).
--
--   * Every SCAN_TICKS ticks it asks the game for the enemy closest to the PLAYER (within DEFEND_RADIUS).
--   * If that enemy is out of the gun's range it walks towards it (round obstacles, scripts/pathing.lua), but
--     never further than LEASH tiles from you; once in range it stands still and shoots.
--   * With nothing to shoot it just goes on following you.
--
-- Weapon and ammo: the Engineer has its own gun slots and ammo slots (it is a copy of the character).
--   * Gun:  a spare gun from YOUR inventory if you have one, otherwise it gets FREE_GUN for nothing
--           (set FREE_GUN = nil to make a spare gun in your inventory compulsory).
--   * Ammo: taken from YOUR inventory (up to AMMO_KEEP magazines at a time). No ammo = it does not engage.
--   Everything is given back to you when you untick the box or dismiss the Engineer.
--
-- State: storage.defend[player_index] = true/false;  data.defend = {target, next_scan, next_equip, armed,
--        range, shooting, gun_borrowed, gun_free, note}

local common = require("scripts.common")

local M = {}

M.DEFEND_RADIUS = 25   -- an enemy this close to the player is a target (tiles)
M.LEASH         = 32   -- it never goes further than this from the player (the follow-teleport is at 40)

local SCAN_TICKS    = 15
local EQUIP_TICKS   = 60
local AMMO_KEEP     = 20   -- magazines it carries at most
local AMMO_LOW      = 8    -- it takes more when it has fewer than this
local DEFAULT_RANGE = 18   -- gun range when the prototype can't be read (submachine gun)
local FREE_GUN      = "submachine-gun"

-- The first one found in your inventory is used, so put your favourite first (cheap ammo first by default).
local GUN_PREFERENCE  = {"submachine-gun", "shotgun", "pistol"}
local AMMO_PREFERENCE = {"firearm-magazine", "piercing-rounds-magazine", "uranium-rounds-magazine",
                         "shotgun-shell", "piercing-shotgun-shell"}

-- used only when the prototype's own data can't be read
local FALLBACK_CATEGORY = {
  ["pistol"] = "bullet", ["submachine-gun"] = "bullet",
  ["shotgun"] = "shotgun-shell", ["combat-shotgun"] = "shotgun-shell",
  ["firearm-magazine"] = "bullet", ["piercing-rounds-magazine"] = "bullet", ["uranium-rounds-magazine"] = "bullet",
  ["shotgun-shell"] = "shotgun-shell", ["piercing-shotgun-shell"] = "shotgun-shell",
}

---------------------------------------------------------------------
-- Setting
---------------------------------------------------------------------

function M.init()
  storage.defend = storage.defend or {}
end

function M.enabled(player_index)
  return storage.defend ~= nil and storage.defend[player_index] == true
end

function M.remove_player(player_index)
  if storage.defend then storage.defend[player_index] = nil end
end

---------------------------------------------------------------------
-- Prototype helpers (every read is guarded: a missing property on a prototype throws)
---------------------------------------------------------------------

local function gun_info(name)
  local cats, range = {}, nil
  local proto = prototypes.item[name]
  local ap = proto and common.try_get(proto, "attack_parameters")
  if ap then
    local list = common.try_get(ap, "ammo_categories")
    if list then
      for _, cat in pairs(list) do cats[cat] = true end
    end
    range = common.try_get(ap, "range")
  end
  if next(cats) == nil then cats[FALLBACK_CATEGORY[name] or "bullet"] = true end
  return cats, (type(range) == "number" and range > 0) and range or DEFAULT_RANGE
end

local function ammo_category(name)
  local proto = prototypes.item[name]
  if not proto or proto.type ~= "ammo" then return nil end
  local ok, at = pcall(function() return proto.get_ammo_type() end)
  if ok and at and at.category then return at.category end
  return FALLBACK_CATEGORY[name]
end

local function find_spare_gun(pinv)
  local present = {}
  for _, s in pairs(pinv.get_contents()) do
    local proto = prototypes.item[s.name]
    if proto and proto.type == "gun" and not present[s.name] then present[s.name] = s end
  end
  for _, name in ipairs(GUN_PREFERENCE) do
    if present[name] then return present[name] end
  end
  for _, s in pairs(present) do return s end
  return nil
end

local function pick_ammo(pinv, cats)
  local avail = {}
  for _, s in pairs(pinv.get_contents()) do
    local cat = ammo_category(s.name)
    if cat and cats[cat] and not avail[s.name] then avail[s.name] = s end
  end
  for _, name in ipairs(AMMO_PREFERENCE) do
    if avail[name] then return avail[name] end
  end
  for _, s in pairs(avail) do return s end
  return nil
end

local function defend_data(data)
  data.defend = data.defend or {}
  return data.defend
end

---------------------------------------------------------------------
-- Gun and ammo
---------------------------------------------------------------------

-- Makes sure the Engineer holds a gun and some ammo. Sets d.armed and d.range.
function M.equip(player, data)
  local c = data.entity
  local d = defend_data(data)
  local guns = c.get_inventory(defines.inventory.character_guns)
  local ammo = c.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then
    d.armed, d.note = false, "no gun slots"
    return false
  end
  local pinv = player.get_main_inventory()

  if guns.is_empty() then
    local spare = pinv and find_spare_gun(pinv)
    if spare and guns.insert{name = spare.name, count = 1, quality = spare.quality} > 0 then
      pinv.remove{name = spare.name, count = 1, quality = spare.quality}
      d.gun_borrowed = {name = spare.name, quality = spare.quality}
    elseif FREE_GUN and prototypes.item[FREE_GUN] then
      guns.insert{name = FREE_GUN, count = 1}
      d.gun_free = true
    end
  end

  local gun_name
  for i = 1, #guns do
    local stack = guns[i]
    if stack.valid_for_read then
      gun_name = stack.name
      pcall(function() c.selected_gun_index = i end)
      break
    end
  end
  if not gun_name then
    d.armed, d.note = false, "no gun"
    return false
  end
  local cats, range = gun_info(gun_name)
  d.range = range

  local have = 0
  for _, s in pairs(ammo.get_contents()) do have = have + s.count end
  if have < AMMO_LOW and pinv then
    local pick = pick_ammo(pinv, cats)
    if pick then
      local want = math.min(AMMO_KEEP - have, pick.count)
      local inserted = ammo.insert{name = pick.name, count = want, quality = pick.quality}
      if inserted > 0 then
        pinv.remove{name = pick.name, count = inserted, quality = pick.quality}
        have = have + inserted
      end
    end
  end
  d.armed = have > 0
  d.note = (not d.armed) and "out of ammo" or nil
  return d.armed
end

local function give_back(player, c, s)
  local inserted = 0
  if player and player.valid then
    inserted = player.insert{name = s.name, count = s.count, quality = s.quality}
  end
  if inserted < s.count then
    c.surface.spill_item_stack{
      position = c.position,
      stack = {name = s.name, count = s.count - inserted, quality = s.quality},
      enable_looted = false,
    }
  end
end

-- Stops shooting (the Engineer keeps its gun).
function M.release(data)
  local d = data.defend
  if d and d.shooting then
    d.shooting = false
    if data.entity and data.entity.valid then
      data.entity.shooting_state = {state = defines.shooting.not_shooting}
    end
  end
end

-- Gives the ammo (and a borrowed gun) back to the player; a free gun just disappears.
function M.unequip(player, data)
  local c = data and data.entity
  if not (c and c.valid) then return end
  M.release(data)
  local d = data.defend or {}
  local ammo = c.get_inventory(defines.inventory.character_ammo)
  if ammo then
    for _, s in pairs(ammo.get_contents()) do give_back(player, c, s) end
    ammo.clear()
  end
  local guns = c.get_inventory(defines.inventory.character_guns)
  if guns then
    if d.gun_borrowed then
      give_back(player, c, {name = d.gun_borrowed.name, count = 1, quality = d.gun_borrowed.quality})
    end
    guns.clear()
  end
  data.defend = nil
end

function M.set_enabled(player, on)
  storage.defend = storage.defend or {}
  storage.defend[player.index] = on and true or nil
  if not on then
    local data = storage.companions and storage.companions[player.index]
    if data then M.unequip(player, data) end
  end
end

---------------------------------------------------------------------
-- Per tick
---------------------------------------------------------------------

-- Returns true when the Engineer is busy with an enemy this tick (the caller must NOT make it follow).
function M.run(player, data)
  local c = data.entity
  local char = player.character
  if not (M.enabled(player.index) and char and char.valid and c.surface.index == char.surface.index) then
    M.release(data)
    return false
  end
  local d = defend_data(data)

  if game.tick >= (d.next_equip or 0) then
    d.next_equip = game.tick + EQUIP_TICKS
    M.equip(player, data)
  end
  if not d.armed then
    M.release(data)
    return false
  end

  local target = d.target
  if target and not target.valid then target = nil end
  if not target or game.tick >= (d.next_scan or 0) then
    d.next_scan = game.tick + SCAN_TICKS
    target = c.surface.find_nearest_enemy{
      position = char.position, max_distance = M.DEFEND_RADIUS, force = player.force,
    }
    d.target = target
  end
  if not (target and target.valid) then
    M.release(data)
    return false
  end
  if common.dist2(c.position, char.position) > M.LEASH * M.LEASH then
    d.target = nil
    M.release(data)
    return false
  end

  local reach = (d.range or DEFAULT_RANGE) - 1
  local tp = target.position
  if common.dist2(c.position, tp) > reach * reach then
    common.walk_towards(data, tp, math.max(reach - 2, 1))
  else
    c.walking_state = {walking = false}
    data.nav = nil
  end
  c.shooting_state = {state = defines.shooting.shooting_enemies, position = tp}
  d.shooting = true
  data.status = "Defending you: shooting " .. target.name
  return true
end

-- What to show as the status while following, when defending is on but nothing is being shot.
function M.idle_status(player, data)
  if not M.enabled(player.index) then return nil end
  local d = data.defend
  if d and d.note then return "Following you (defending is on, but: " .. d.note .. ")" end
  return "Following you (defending)"
end

return M
