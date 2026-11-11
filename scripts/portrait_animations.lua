-- Portrait animations of the interaction window.
--
-- A Factorio animation is a SPRITE SHEET; a GUI cannot play one by itself, so every frame becomes a sprite
-- prototype ("ec-portrait-<name>-<n>", cropped out of the sheet by data-final-fixes.lua) and scripts/interaction.lua
-- swaps the sprite of the window every `ticks` ticks.
--
-- Loaded by data-final-fixes.lua AND by control.lua, so it must not use any runtime-only API at load time.
--
-- WHERE ANIMATIONS COME FROM (later sources override earlier ones with the same name):
--   1. the built-in ones below (graphics/portrait/*.png, placeholders; the fallback when nothing else is found)
--   2. PACKS: any other mod can add a "mod-data" prototype whose name starts with "engineer-companion-pack-" and
--      whose `data` is {animations = {...}, aliases = {...}, dialogues = {...}} (see custom/README.md); that mod
--      must depend on engineer-companion so that it loads after it
--   3. the FOLDERS of this mod: custom/<animation name>/animation.lua + custom/<animation name>/sheet.png
--      (e.g. custom/talk/, custom/idle/, custom/working/, custom/happy/...). Factorio cannot list a folder, so the
--      mod looks for custom/<name>/animation.lua for each known name (KNOWN_FOLDERS + `folders` of
--      custom/animations.lua) and uses the folder when that file exists.
--   4. custom/animations.lua (manual manifest: frame_size, aliases, extra folder names, or sheets from anywhere)
--
-- An animation:
--   file     sprite sheet ("__engineer-companion__/custom/x.png" or "__yourmod__/x.png")
--   frames   number of frames
--   columns  frames per row of the sheet (default: all in one row)
--   width, height   size of ONE frame in pixels (default: frame_size)
--   ticks    game ticks each frame is shown
--   loop     false = plays once and stays on the last frame (default true)
--   caption  shown under the portrait
--
-- ALIASES: {working = "my_hammering"} makes everything that asks for "working" show "my_hammering" instead, so a
-- custom character does not have to redraw every built-in animation name.

local M = {}

M.PACK_PREFIX = "engineer-companion-pack-"
M.scale = 1 -- extra scale of the sprites (the window size itself is set in scripts/interaction.lua)

-- require() that returns nil when the file does not exist. A file that exists but is broken (typo...) is reported
-- in factorio-current.log instead of being swallowed silently.
local function try_require(name)
  local ok, result = pcall(require, name)
  if ok then
    if type(result) == "table" then return result end
    return nil
  end
  local msg = tostring(result)
  local low = msg:lower()
  local missing = low:find("not found", 1, true) or low:find("no such file", 1, true)
    or low:find("couldn't find", 1, true) or low:find("could not find", 1, true)
    or low:find("does not exist", 1, true) or low:find("doesn't exist", 1, true)
  if not missing then log("[engineer-companion] cannot load " .. name .. ": " .. msg) end
  return nil
end

local custom = try_require("custom.animations") -- loaded now: require() is not allowed at runtime
-- custom/folders.lua: {folders = {...}} written by build_custom.py (every custom/<n>/ that has an animation.lua)
local generated = try_require("custom.folders")

local function strip(name) return "__engineer-companion__/graphics/portrait/" .. name .. ".png" end

local BUILTIN = {
  idle     = {file = strip("idle"),     frames = 4, ticks = 24, caption = "Listening"},
  talk     = {file = strip("talk"),     frames = 4, ticks = 6,  caption = "Talking"},
  working  = {file = strip("working"),  frames = 4, ticks = 10, caption = "Working"},
  thinking = {file = strip("thinking"), frames = 4, ticks = 18, caption = "Thinking"},
  happy    = {file = strip("happy"),    frames = 4, ticks = 10, caption = "Happy"},
  worried  = {file = strip("worried"),  frames = 4, ticks = 14, caption = "Worried"},
  tired    = {file = strip("tired"),    frames = 4, ticks = 30, caption = "Tired"},
}

-- The animation names that are looked for as folders: custom/<name>/animation.lua + custom/<name>/sheet.png.
-- More names (your own animations, used by custom/states.lua or by an alias) go in `folders` of custom/animations.lua.
local KNOWN_FOLDERS = {"idle", "talk", "working", "thinking", "happy", "worried", "tired", "noise"}

local FOLDER_ROOT = "__engineer-companion__/custom/"

-- {animations, aliases} found in the folders custom/<name>/
local function load_folders()
  local names, seen = {}, {}
  local function add(name)
    if type(name) ~= "string" or seen[name] then return end
    if not name:match("^[%w_%-]+$") then
      log("[engineer-companion] ignored folder name '" .. name .. "' (letters, digits, _ and - only)")
      return
    end
    seen[name] = true
    names[#names + 1] = name
  end
  for _, name in ipairs(KNOWN_FOLDERS) do add(name) end
  for _, name in ipairs(generated and generated.folders or {}) do add(name) end
  for _, name in ipairs(custom and custom.folders or {}) do add(name) end

  local animations, aliases = {}, {}
  for _, name in ipairs(names) do
    local cfg = try_require("custom." .. name .. ".animation")
    if cfg then
      if cfg.alias then
        aliases[name] = cfg.alias
      else
        -- Factorio's own names are accepted too (what tools/animation exporters write): frame_count, line_length,
        -- filename, animation_speed (frames per tick -> ticks per frame). direction_count / scale / shift are
        -- ignored: a portrait has one direction (the first row of frames) and its size comes from the window.
        local frames = cfg.frames or cfg.frame_count
        if type(frames) ~= "number" or frames < 1 then
          log("[engineer-companion] custom/" .. name .. "/animation.lua: `frames` (number of frames of the sheet) is missing")
        else
          local a = {}
          for k, v in pairs(cfg) do a[k] = v end
          local file = cfg.file or cfg.filename or "sheet.png"
          if not file:find("^__") then file = FOLDER_ROOT .. name .. "/" .. file end -- relative to the folder
          a.file = file
          a.frames = frames
          a.columns = cfg.columns or cfg.line_length
          local ticks = cfg.ticks
          if not ticks and type(cfg.animation_speed) == "number" and cfg.animation_speed > 0 then
            ticks = math.max(1, math.floor(1 / cfg.animation_speed + 0.5))
          end
          a.ticks = ticks or 10
          a.caption = a.caption or (BUILTIN[name] and BUILTIN[name].caption) or name
          animations[name] = a
        end
      end
    end
  end
  return {animations = animations, aliases = aliases}
end

local from_folders = load_folders() -- loaded now: require() is not allowed at runtime

-- {data of every pack} out of a table of mod-data prototypes (data.raw["mod-data"] or prototypes.mod_data)
function M.packs_from(mod_data)
  local names = {}
  for name in pairs(mod_data or {}) do
    if name:sub(1, #M.PACK_PREFIX) == M.PACK_PREFIX then names[#names + 1] = name end
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local d = mod_data[name].data
    if type(d) == "table" then out[#out + 1] = d end
  end
  return out
end

-- The registry: {frame_size, animations, aliases}
function M.build(packs)
  local reg = {frame_size = {width = 256, height = 256}, animations = {}, aliases = {}}
  for name, a in pairs(BUILTIN) do reg.animations[name] = a end

  local function apply(src)
    if type(src) ~= "table" then return end
    if src.frame_size then reg.frame_size = src.frame_size end
    for name, a in pairs(src.animations or {}) do reg.animations[name] = a end
    for from, to in pairs(src.aliases or {}) do reg.aliases[from] = to end
  end
  for _, p in ipairs(packs or {}) do apply(p) end
  apply(from_folders)
  apply(custom)
  return reg
end

local cached
-- Runtime: built once from prototypes.mod_data (the packs that are installed) + custom/animations.lua.
function M.get()
  if not cached then
    cached = M.build(M.packs_from(prototypes.mod_data))
  end
  return cached
end

-- The animation that really plays when `name` is asked for (aliases, unknown names -> idle).
function M.resolve(name)
  local reg = M.get()
  local target = reg.aliases[name] or name
  if reg.animations[target] then return target end
  return reg.animations.idle and "idle" or next(reg.animations)
end

-- Size of one frame of an animation.
function M.frame_size(anim)
  local reg = M.get()
  return anim.width or reg.frame_size.width, anim.height or reg.frame_size.height
end

function M.sprite_name(animation, frame)
  return "ec-portrait-" .. animation .. "-" .. frame
end

return M
