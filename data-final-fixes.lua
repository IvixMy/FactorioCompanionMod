-- The companion's OWN body (idle, running, mining... in the world): body/body.lua is written by build_custom.py from
-- frames/companion/ and changes engineer-companion-character only; the player's character is not touched.
-- No body/body.lua = the companion keeps the vanilla look.
do
  local ok, err = pcall(require, "body.body")
  if not ok then
    local low = tostring(err):lower()
    local missing = low:find("not found", 1, true) or low:find("no such file", 1, true)
      or low:find("couldn't find", 1, true) or low:find("could not find", 1, true)
      or low:find("does not exist", 1, true) or low:find("doesn't exist", 1, true)
    if not missing then error("[engineer-companion] body/body.lua is broken: " .. tostring(err)) end
  end
end

-- Portrait sprites: one sprite prototype per frame of every animation (built-in + packs + the folders custom/<name>/ + custom/animations.lua).
-- Runs in data-final-fixes so that the packs of other mods (mod-data prototypes) are already there.
local portraits = require("scripts.portrait_animations")

local reg = portraits.build(portraits.packs_from(data.raw["mod-data"]))
local sprites = {}
for name, anim in pairs(reg.animations) do
  local w = anim.width or reg.frame_size.width
  local h = anim.height or reg.frame_size.height
  local columns = anim.columns or anim.frames
  for i = 1, anim.frames do
    sprites[#sprites + 1] = {
      type = "sprite",
      name = portraits.sprite_name(name, i),
      filename = anim.file,
      x = ((i - 1) % columns) * w,
      y = math.floor((i - 1) / columns) * h,
      width = w,
      height = h,
      priority = "extra-high-no-scale",
      flags = {"gui-icon"},
    }
  end
end
data:extend(sprites)

-- Sounds: one "sound" prototype per group listed in sound/sounds.lua (written by build_custom.py).
-- A group with several files plays a random one each time.
local ok, groups = pcall(require, "sound.sounds")
if ok and type(groups) == "table" then
  local protos = {}
  for group, files in pairs(groups) do
    local variations = {}
    for _, file in ipairs(files) do variations[#variations + 1] = {filename = file, volume = 1} end
    if #variations > 0 then
      protos[#protos + 1] = {type = "sound", name = "ec-sound-" .. group, variations = variations}
    end
  end
  if #protos > 0 then data:extend(protos) end
end
