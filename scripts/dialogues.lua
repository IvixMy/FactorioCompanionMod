-- What the Companion says.
--
-- SITUATIONS are keys (greeting, status_idle, research_finished...). Each has a list of LINES; one is picked at
-- random. A line is a string, a LocalisedString, or {text = ..., animation = "happy", seconds = 3}.
-- {name} placeholders are filled from the variables the caller passes ({status}, {tech}, {pct}...).
--
-- WHERE LINES COME FROM:
--   1. the built-in ones below
--   2. PACKS (mod-data "engineer-companion-pack-*", field `dialogues`): their lines are ADDED to the situation, unless
--      the pack also sets `replace_dialogues = true`
--   3. custom/dialogues.lua of THIS mod: a situation listed there REPLACES the built-in lines
--
-- Situations the mod uses: greeting, farewell, status_idle, status_working, status_blocked, status_research,
-- mode_follow, mode_wait, mode_auto_build, nothing_special, research_finished, too_far, not_summoned.
-- Your own code (custom/states.lua) can use any other key: dialogues.pick("my_key", vars).

local names = require("scripts.names")
local portraits = require("scripts.portrait_animations")

local M = {}

local function try_require(name)
  local ok, result = pcall(require, name)
  if ok and type(result) == "table" then return result end
  return nil
end

local custom = try_require("custom.dialogues") -- loaded now: require() is not allowed at runtime

local BUILTIN = {
  greeting = {
    "Hey! What do you need?",
    "Hello! Ready when you are.",
    {text = "Oh, hi! I was just thinking about the base.", animation = "thinking"},
  },
  farewell = {"See you around.", "Back to work, then."},
  status_idle = {"{status}", "All quiet. {status}"},
  status_working = {"{status}", {text = "Busy, busy... {status}", animation = "working"}},
  status_blocked = {{text = "Something is in the way: {status}", animation = "worried"}},
  status_research = {{text = "The labs are researching {tech} ({pct}%).", animation = "thinking"}},
  mode_follow = {"Understood, I'll stay right behind you.", "Following you."},
  mode_wait = {{text = "Okay, I'll wait here.", animation = "tired"}},
  mode_auto_build = {"On it. I'll build from the chests and look after the base.", "Leave the base to me."},
  nothing_special = {"Nothing special to report."},
  research_finished = {{text = "Research finished: {tech}!", animation = "happy", seconds = 20}},
  too_far = {"{companion} is too far away to talk (call them to you first)."},
  not_summoned = {"{companion} is not summoned."},
}

local cached
local function catalog()
  if cached then return cached end
  local cat = {}
  for key, lines in pairs(BUILTIN) do cat[key] = {table.unpack(lines)} end

  for _, pack in ipairs(portraits.packs_from(prototypes.mod_data)) do
    for key, lines in pairs(pack.dialogues or {}) do
      if pack.replace_dialogues or not cat[key] then cat[key] = {} end
      for _, l in ipairs(lines) do cat[key][#cat[key] + 1] = l end
    end
  end
  for key, lines in pairs(custom or {}) do
    if type(lines) == "table" then cat[key] = lines end
  end
  cached = cat
  return cat
end

local function fill(text, vars)
  if type(text) ~= "string" or not vars then return text end
  return (text:gsub("{(%w_?%w*)}", function(k)
    local v = vars[k]
    return v ~= nil and tostring(v) or "{" .. k .. "}"
  end))
end

-- {text, animation|nil, seconds|nil} for a situation (nil when there is no line for it)
function M.pick(situation, vars)
  vars = vars or {}
  if vars.companion == nil then vars.companion = names.get() end -- {companion} in any line
  local lines = catalog()[situation]
  if not (lines and #lines > 0) then return nil end
  local l = lines[math.random(#lines)]
  if type(l) == "table" and l.text ~= nil then
    return {text = fill(l.text, vars), animation = l.animation, seconds = l.seconds, sound = l.sound}
  elseif type(l) == "table" and l[1] ~= nil and type(l[1]) == "string" and l.text == nil then
    return {text = l} -- a LocalisedString
  end
  return {text = fill(l, vars)}
end

-- Just the text ("" when there is none).
function M.text(situation, vars)
  local l = M.pick(situation, vars)
  return l and l.text or ""
end

return M
