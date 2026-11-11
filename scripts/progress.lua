-- "Progress game" controller.
--
-- Looks at the technology tree (scripts/research.lua) to see how far the game has come, picks the
-- active playbook stage (scripts/playbooks.lua) and works through its objectives one at a time
-- (scripts/objectives/*.lua). Nothing is remembered in the action itself: objectives keep their
-- work in zones (scripts/zones.lua), so stopping and restarting the action resumes seamlessly.

local research   = require("scripts.research")
local playbooks  = require("scripts.playbooks")
local objectives = require("scripts.objectives")
local actions    = require("scripts.actions.core")
local upkeep     = require("scripts.upkeep")
local goals      = require("scripts.goals")
local loadout    = require("scripts.loadout")
local deposit    = require("scripts.deposit")
local tasks      = require("scripts.tasks")
local names      = require("scripts.names")

local M = {}

local INTERVAL = 60 -- ticks between evaluations

function M.init()
  storage.progress = storage.progress or {}
end

local function state_for(player_index)
  M.init()
  local st = storage.progress[player_index]
  if not st then
    st = {objectives = {}}
    storage.progress[player_index] = st
  end
  return st
end

function M.remove(player_index)
  if storage.progress then storage.progress[player_index] = nil end
end

local function research_text(force, prog)
  local current = force.current_research
  if current then return "researching " .. current.name end
  if prog.next then return "next research: " .. prog.next.name end
  if prog.trigger then return "needs manual step: " .. prog.trigger.name end
  return "no research available"
end

-- Called every tick by the action; does real work once per INTERVAL.
function M.tick(player, data, a)
  -- when the planner is paused waiting to refuel something, don't wait for the next interval
  local urgent = upkeep.holding(data) and not data.task
  if game.tick < (a.next_eval or 0) and not urgent then return end
  a.next_eval = game.tick + INTERVAL

  local force = player.force
  goals.check(player, data) -- trigger technologies (craft / build / mine) the game could not see
  local prog = research.progress(force)
  if prog.missing_target then
    return actions.cancel(data, "cancelled (technology '" .. research.TARGET .. "' does not exist in this game)")
  end
  if prog.finished then
    player.print(names.prefix() .. "'" .. research.TARGET .. "' is researched. The game is progressed as far as I can take it.")
    return actions.cancel(data, "done (" .. research.TARGET .. " researched)")
  end

  local stage, list = playbooks.current(force)
  local st = state_for(player.index)

  -- A priority technology (research.PRIORITY: logistics, which unlocks the belt factory) is researched before
  -- anything else once the bootstrap is over, even when something else (steel...) is already in the queue.
  local priority = research.priority_tech(force)
  if priority and stage and stage.id ~= "bootstrap" then research.focus(force, priority) end

  local setting = settings.get_player_settings(player)["ec-progress-queue-research"]
  if setting and setting.value then research.queue_if_idle(force, prog.next) end

  -- 0. PRIORITY: the objectives come first. Only a machine that is about to stop (critical) is
  --    refuelled before them; everything else is refuelled when the objectives can't continue
  --    (step 2 below), so the companion doesn't spend its time shuttling coal.
  local up_status, up_note = upkeep.step(player, data, {critical = true})
  if up_status == "working" then
    a.summary = string.format("Progress %d%% (%d/%d techs) | upkeep (urgent): %s",
      prog.pct, prog.done, prog.total, up_note or "")
    data.action_status = a.summary
    return
  end

  -- 0b. Carried loadout: when something runs low, one round to the chests tops it up before the next objective
  if not data.task then
    local restock = loadout.next_task(player, data, {mode = "low"})
    if restock then
      tasks.start(data, restock)
      a.summary = string.format("Progress %d%% (%d/%d techs) | %s", prog.pct, prog.done, prog.total, data.status or "restocking")
      data.action_status = a.summary
      return
    end
  end

  local focus_text, satisfied, planned = nil, 0, 0
  local focus_status, focus_def

  -- BACKGROUND objectives (def.background: the hand-fed research) are looked at first: feeding the labs must not
  -- wait until the objectives in front of it are finished (a lab being built, a factory being fed...). They only
  -- hold the others up while they have a task running; blocked / waiting ones let the list go on.
  local ordered = {}
  for _, params in ipairs(list) do
    local d = objectives.get(params.id)
    if d and d.implemented and d.background then ordered[#ordered + 1] = params end
  end
  for _, params in ipairs(list) do
    local d = objectives.get(params.id)
    if not (d and d.implemented and d.background) then ordered[#ordered + 1] = params end
  end

  for _, params in ipairs(ordered) do
    local def = objectives.get(params.id)
    if not (def and def.implemented) then
      planned = planned + 1
    else
      local ostate = st.objectives[params.id] or {}
      st.objectives[params.id] = ostate
      local status, note = def.step({player = player, data = data, params = params, state = ostate})
      if def.background and status == "working" and not data.task then status = "blocked" end -- only waiting
      if status == "satisfied" then
        satisfied = satisfied + 1
      elseif def.background and status == "blocked" then
        satisfied = satisfied + 1 -- nothing to do for it right now; the list goes on
      else
        focus_text = string.format("%s: %s (%s)", def.caption or def.id, note or "", status)
        focus_status = status
        focus_def = def
        break
      end
    end
  end

  -- the focused objective may limit the refuelling to the burners that matter for it (def.upkeep_scope)
  data.upkeep_scope = focus_def and focus_def.upkeep_scope or nil

  -- 2. the objectives are blocked / have nothing left to do: now is the time to top up fuel
  if focus_status ~= "working" and not data.task then
    local s2, n2 = upkeep.step(player, data)
    if s2 then up_status, up_note = s2, n2 end
    if s2 == "working" then focus_text = "upkeep: " .. (n2 or "") end
  end

  -- 3. nothing left to do right now: put what is above the MAX of the requests into a free storage chest
  if focus_status ~= "working" and not data.task then
    local dep = deposit.next_task(player, data)
    if dep then
      tasks.start(data, dep)
      focus_text = data.status
    end
  end

  a.summary = string.format("Progress %d%% (%d/%d techs) | %s | stage %s | %s%s",
    prog.pct, prog.done, prog.total, research_text(force, prog), stage and stage.id or "final",
    focus_text or string.format("%d objectives satisfied, %d planned", satisfied, planned),
    up_status == "blocked" and (" | WARNING: " .. (up_note or "")) or "")
  data.action_status = a.summary
end

return M
