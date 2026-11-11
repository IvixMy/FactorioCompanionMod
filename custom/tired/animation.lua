-- Animation "tired". Tired: shown while the Engineer is told to wait.
--
-- HOW TO CHANGE IT: replace sheet.png (same folder) with your sprite sheet (all frames of this animation in ONE png,
-- every frame the same size, read left to right then top to bottom), fix the numbers below, RESTART Factorio.
-- To remove it, delete this folder (or this file): the mod falls back to its built-in placeholder.
return {
  frames = 4,   -- number of frames in sheet.png (REQUIRED)
  ticks = 30,    -- game ticks each frame is shown (60 ticks = 1 second)

  -- All optional:
  -- columns = 4,   -- frames per row of the sheet (default: all frames in one row)
  -- width = 256, height = 256,   -- size of ONE frame in pixels (default: frame_size of custom/animations.lua, 256x256)
  -- loop = false,   -- false: plays once and holds the last frame (default true)
  -- caption = "Tired",   -- text under the portrait
  -- file = "sheet.png",   -- name of the sheet inside this folder (default sheet.png)
  -- alias = "idle",   -- no sheet at all: show another animation instead (then this folder needs no sheet.png)
}
