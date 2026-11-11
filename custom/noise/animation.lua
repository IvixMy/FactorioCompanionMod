-- Animation "noise": the TV static that plays for a moment whenever the Engineer's animation changes
-- (idle -> talk -> working -> thinking -> happy ...). 6 frames of 256x256 in one row.
-- scripts/interaction.lua shows it for NOISE_TICKS, together with the state-change sound.
return {
  file = "sheet.png",
  frames = 6,
  columns = 6,
  width = 256,
  height = 256,
  ticks = 3,        -- the window refreshes every 3 ticks: this is the fastest it can go
  caption = "...",
}
