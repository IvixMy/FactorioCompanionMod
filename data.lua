-- Companion body: a copy of the player character, at the same speed as the player. It KEEPS the character's
-- collision mask: buildings, trees, cliffs and water stop it like they stop you, and scripts/pathing.lua finds
-- its way round them (it used to have an empty mask and flew over everything).
local companion = table.deepcopy(data.raw["character"]["character"])
companion.name = "engineer-companion-character"
companion.localised_name = {"entity-name.engineer-companion-character"}
companion.running_speed = 0.15 -- same as the player; raise to make it faster
companion.minable = nil
-- Not selectable: with the mouse over it the player's aim snapped onto the companion while shooting enemies next to
-- it. Talking to it with E (open GUI) uses the cursor position instead (control.lua, "ec-interact-click").
companion.selectable_in_game = false
companion.mining_speed = 2.5 -- hand-mining speed (real mining, with the mining animation)

-- (the portrait sprites are made in data-final-fixes.lua, after the packs of other mods are known)

data:extend{
  companion,
  {
    type = "custom-input",
    name = "ec-toggle-menu",
    key_sequence = "CONTROL + SHIFT + E",
    action = "lua",
  },
  { -- talk to the Engineer (it must be near you)
    type = "custom-input",
    name = "ec-interact",
    key_sequence = "SHIFT + F",
    action = "lua",
  },
  { -- the "open GUI" key (E) while the mouse is over the Engineer
    type = "custom-input",
    name = "ec-interact-click",
    key_sequence = "",
    linked_game_control = "open-gui",
    consuming = "none",
    action = "lua",
  },
}
