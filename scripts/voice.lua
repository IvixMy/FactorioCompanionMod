-- Voice (0.20.0): the companion speaks in the WORLD, outside the Talk window.
--
-- A SITUATION is {id, group, priority, cooldown, duration, positional, detect}:
--   id          "idle", "meet", ...; settings read: ec-voice-<id> (bool, on/off per situation)
--   group       sound group "voice_<id>" (sound/sounds.lua; one file = one line, several files = a random one)
--   priority    higher wins when several are ready at the same moment; >= ALERT_PRIORITY may interrupt a line that is
--               still playing and ignores the gap between lines
--   cooldown    ticks before the same situation may play again
--   duration    ticks a line is considered to be playing (nothing else starts meanwhile, alerts excepted)
--   positional  true: heard at the companion (fades with distance); false: heard by the player anywhere (alerts)
--   detect(ctx) true when the situation is happening NOW. It runs every poll (POLL_TICKS), also while a line is
--               playing, so it can keep its own edge tracking in ctx.v (the per-companion table data.voice).
--               ctx = {player, data, c (the companion), char (the player's character or nil), tick, v, cfg}
--
-- Built in: idle, meet (long time since it saw the player), working, crafting, thinking (a research starts), low_power (the main grid cannot keep
-- up), enemy_attack (enemy units near the player). More: custom/voices.lua, or M.register() from any module.
--
-- Settings (per player): ec-voice-enabled, ec-voice-volume, ec-voice-gap, ec-voice-captions, ec-voice-<id>,
-- ec-voice-idle-seconds, ec-voice-meet-minutes, ec-voice-enemy-radius.
-- Remote interface "engineer_companion_voice": say(player_index, id), situations().

local common = require("scripts.common")

local M = {}

M.POLL_TICKS      = 15
M.ALERT_PRIORITY  = 90
M.WORK_GAP        = 900    -- ticks without a task before "working" counts as a new start
M.CRAFT_GAP       = 1200   -- same for crafting
M.MEET_RANGE      = 30     -- tiles: closer than this = "it sees the player"
M.POWER_RADIUS    = 80     -- tiles around the player where machines are sampled for the power check
M.POWER_SAMPLE    = 60     -- machines looked at
M.POWER_MIN       = 4      -- ... at least this many must be powered machines for a verdict
M.POWER_LOW_SHARE = 0.3    -- ... of them this share on low power = "low generation"
M.POWER_EVERY     = 300    -- ticks between two power checks
M.ENEMY_EVERY     = 30
M.ENEMY_MIN_UNITS = 3

local function try_require(name)
  local ok, result = pcall(require, name)
  if ok then return result end
  return nil
end
local custom_voices = try_require("custom.voices") -- loaded now: require() is not allowed at runtime
local sound_groups = try_require("sound.sounds") or {}

M.situations = {} -- id -> definition
M.order = {}      -- ids, highest priority first

function M.register(def)
  assert(def.id and def.detect, "voice.register: id and detect are required")
  def.group = def.group or ("voice_" .. def.id)
  def.priority = def.priority or 50
  def.cooldown = def.cooldown or 3600
  def.duration = def.duration or 240
  if def.positional == nil then def.positional = true end
  if not M.situations[def.id] then M.order[#M.order + 1] = def.id end
  M.situations[def.id] = def
  table.sort(M.order, function(a, b)
    local pa, pb = M.situations[a].priority, M.situations[b].priority
    if pa ~= pb then return pa > pb end
    return a < b
  end)
end

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------

local function read_cfg(player)
  local s = settings.get_player_settings(player)
  local function get(name, default)
    local v = s[name]
    if v == nil then return default end
    return v.value
  end
  return {
    enabled = get("ec-voice-enabled", true),
    volume = get("ec-voice-volume", 70) / 100,
    gap = get("ec-voice-gap", 8) * 60,
    captions = get("ec-voice-captions", false),
    idle_ticks = get("ec-voice-idle-seconds", 60) * 60,
    meet_ticks = get("ec-voice-meet-minutes", 10) * 3600,
    enemy_radius = get("ec-voice-enemy-radius", 60),
    on = function(id) return get("ec-voice-" .. id, true) end,
  }
end

---------------------------------------------------------------------
-- Playing
---------------------------------------------------------------------

local function voice_state(data)
  data.voice = data.voice or {last = {}, busy_until = 0, next_line = 0}
  return data.voice
end

local function has_sound(def)
  local files = sound_groups[def.group]
  return files ~= nil and #files > 0
end

-- Plays the line of a situation now (the caller has decided: cooldown, busy and gap are checked in M.tick).
local function play(player, data, def, cfg)
  local c = data.entity
  local v = voice_state(data)
  local tick = game.tick
  if not has_sound(def) then return false end
  local params = {path = "ec-sound-" .. def.group, volume_modifier = math.max(0, math.min(1, cfg.volume))}
  if def.positional then params.position = c.position end
  player.play_sound(params)
  v.last[def.id] = tick
  v.busy_until = tick + def.duration
  v.next_line = tick + cfg.gap
  if cfg.captions then
    pcall(function()
      player.create_local_flying_text{
        text = {"ec-voice.line-" .. def.id}, position = c.position, time_to_live = 150,
      }
    end)
  end
  return true
end

-- Explicit trigger (other modules, the remote interface): plays the situation's line, whatever the detector says.
function M.say(player, data, id)
  local def = M.situations[id]
  if not (def and player and player.valid and data and data.entity and data.entity.valid) then return false end
  local cfg = read_cfg(player)
  if not cfg.enabled or not cfg.on(id) then return false end
  return play(player, data, def, cfg)
end

---------------------------------------------------------------------
-- The poll: every detector runs, the best ready situation plays
---------------------------------------------------------------------

function M.tick(player, data)
  local c = data.entity
  if not (c and c.valid and player.valid) then return end
  local tick = game.tick
  local v = voice_state(data)
  local cfg = read_cfg(player)
  if not cfg.enabled then return end

  local char = player.character
  if char and (not char.valid or char.surface.index ~= c.surface.index) then char = nil end
  local ctx = {player = player, data = data, c = c, char = char, tick = tick, v = v, cfg = cfg}

  local best
  for _, id in ipairs(M.order) do
    local def = M.situations[id]
    local ok, happening = pcall(def.detect, ctx)
    if ok and happening and cfg.on(id) then
      local ready = tick >= (v.last[id] or -math.huge) + def.cooldown
      local alert = def.priority >= M.ALERT_PRIORITY
      local free = alert or (tick >= v.busy_until and tick >= v.next_line)
      if ready and free and not best then best = def end -- M.order is by priority: the first ready one wins
    end
  end
  if best then play(player, data, best, cfg) end
end

---------------------------------------------------------------------
-- Built-in situations
---------------------------------------------------------------------

-- Idle: nothing to do and standing still for a while (setting ec-voice-idle-seconds).
M.register{
  id = "idle", priority = 10, cooldown = 5 * 3600, duration = 300,
  detect = function(ctx)
    local d, v = ctx.data, ctx.v
    local crafting = d.craft_queue and #d.craft_queue > 0
    local walking = ctx.c.walking_state and ctx.c.walking_state.walking
    if d.task or crafting or walking then
      v.idle_since = nil
      return false
    end
    v.idle_since = v.idle_since or ctx.tick
    return ctx.tick - v.idle_since >= ctx.cfg.idle_ticks
  end,
}

-- Meet: it sees the player again after a long time (setting ec-voice-meet-minutes).
M.register{
  id = "meet", priority = 60, cooldown = 600, duration = 120,
  detect = function(ctx)
    local v = ctx.v
    if not ctx.char then return false end
    local near = common.dist2(ctx.c.position, ctx.char.position) <= M.MEET_RANGE * M.MEET_RANGE
    if not near then return false end
    local last = v.last_seen
    v.last_seen = ctx.tick
    return last ~= nil and ctx.tick - last >= ctx.cfg.meet_ticks
  end,
}

-- Working: a task starts after a while without one (follow-and-build jobs that follow each other do not count again).
M.register{
  id = "working", priority = 30, cooldown = 3 * 3600, duration = 180,
  detect = function(ctx)
    local v = ctx.v
    if not ctx.data.task then return false end
    local fresh = ctx.tick - (v.work_last or -math.huge) >= M.WORK_GAP
    v.work_last = ctx.tick
    return fresh
  end,
}

-- Crafting: a hand-craft starts (the queue of scripts/crafting.lua).
M.register{
  id = "crafting", priority = 40, cooldown = 2 * 3600, duration = 160,
  detect = function(ctx)
    local v = ctx.v
    local q = ctx.data.craft_queue
    if not (q and #q > 0) then return false end
    local fresh = ctx.tick - (v.craft_last or -math.huge) >= M.CRAFT_GAP
    v.craft_last = ctx.tick
    return fresh
  end,
}

-- Thinking: the force starts a NEW research (the one in progress when the game loads does not count).
M.register{
  id = "thinking", priority = 35, cooldown = 5 * 3600, duration = 120,
  detect = function(ctx)
    local v = ctx.v
    local research = ctx.c.force.current_research
    local name = research and research.name or nil
    local known = v.research_known
    v.research_known = true
    local changed = name ~= nil and name ~= v.research
    v.research = name
    return known == true and changed
  end,
}

-- Low power: the machines around the player cannot get their power (a sample: this is the "main" grid for the
-- player - the one next to where they are).
M.register{
  id = "low_power", priority = 90, cooldown = 5 * 3600, duration = 220, positional = false,
  detect = function(ctx)
    local v = ctx.v
    if ctx.tick < (v.power_next or 0) then return v.power_low == true end
    v.power_next = ctx.tick + M.POWER_EVERY
    local origin = ctx.char and ctx.char.position or ctx.c.position
    local machines = ctx.c.surface.find_entities_filtered{
      position = origin, radius = M.POWER_RADIUS, force = ctx.c.force, limit = M.POWER_SAMPLE,
      type = {"assembling-machine", "lab", "furnace", "mining-drill", "radar", "roboport"},
    }
    local powered, low = 0, 0
    for _, e in pairs(machines) do
      local status = common.try_get(e, "status")
      if status == defines.entity_status.low_power then
        powered, low = powered + 1, low + 1
      elseif status == defines.entity_status.working or status == defines.entity_status.normal
          or status == defines.entity_status.waiting_for_source_items
          or status == defines.entity_status.waiting_for_space_in_destination
          or status == defines.entity_status.item_ingredient_shortage then
        powered = powered + 1
      end
    end
    v.power_low = powered >= M.POWER_MIN and low / powered >= M.POWER_LOW_SHARE
    return v.power_low -- while it lasts it repeats every `cooldown` (5 min)
  end,
}

-- Enemy attack: enemy units close to the player (radius: ec-voice-enemy-radius), several at once.
M.register{
  id = "enemy_attack", priority = 100, cooldown = 3600, duration = 300, positional = false,
  detect = function(ctx)
    local v = ctx.v
    if ctx.tick < (v.enemy_next or 0) then return false end
    v.enemy_next = ctx.tick + M.ENEMY_EVERY
    local origin = ctx.char and ctx.char.position or ctx.c.position
    local units = ctx.c.surface.find_entities_filtered{
      position = origin, radius = ctx.cfg.enemy_radius, type = "unit", force = "enemy", limit = M.ENEMY_MIN_UNITS,
    }
    local active = #units >= M.ENEMY_MIN_UNITS
    local rising = active and not v.enemy_active -- once per wave: a group that stays near the base does not repeat
    v.enemy_active = active
    return rising
  end,
}

-- custom/voices.lua: `return function(voice) voice.register{...} end`
if type(custom_voices) == "function" then custom_voices(M) end

remote.add_interface("engineer_companion_voice", {
  say = function(player_index, id)
    local player = game.get_player(player_index)
    local data = storage.companions and storage.companions[player_index]
    return M.say(player, data, id)
  end,
  situations = function() return M.order end,
})

return M
