# Customizing the Engineer's portrait and dialogues

The conversation window (SHIFT+F, or E while pointing at the Engineer, or "Talk" in the menu) shows an animated
portrait and a log of what the Engineer says. Both can be changed without touching the mod's code.

## 1. Animations: one folder per animation

```
custom/
  idle/       animation.lua   sheet.png      <- listening (default)
  talk/       animation.lua   sheet.png      <- while it says something
  working/    animation.lua   sheet.png      <- building, crafting, mining...
  thinking/   animation.lua   sheet.png      <- research in progress
  happy/      animation.lua   sheet.png      <- research finished
  worried/    animation.lua   sheet.png      <- blocked
  tired/      animation.lua   sheet.png      <- told to wait
  noise/      animation.lua   sheet.png      <- static, shown for half a second whenever the animation changes
```

To change an animation:

1. drop your **sprite sheet** over `custom/<name>/sheet.png` (all frames of ONE animation in one PNG);
2. open `custom/<name>/animation.lua` and set `frames` (and `ticks`, the speed);
3. **restart Factorio** (sprites are created when the game loads). If you run the mod as a .zip, unzip it into the
   mods folder first, or re-zip after editing.

(Factorio mods cannot list a folder while the game runs, so `animation.lua` is what tells the mod "this folder
exists". Every folder ships with one already, with a placeholder sheet.)

```
+---------+---------+---------+---------+
| frame 1 | frame 2 | frame 3 | frame 4 |      frames = 4   (columns defaults to frames: one row)
+---------+---------+---------+---------+
```

`animation.lua` of a folder (only `frames` is required):

```lua
return {
  frames = 6,        -- number of frames of sheet.png
  ticks = 5,         -- game ticks per frame (60 ticks = 1 second)
  -- columns = 3,    -- frames per row (frames are read left to right, top to bottom); default: one row
  -- width = 300, height = 450,   -- size of ONE frame (default: 256x256, or frame_size of custom/animations.lua)
  -- loop = false,   -- play once and hold the last frame (default true)
  -- caption = "Talking",         -- text under the portrait
  -- file = "sheet.png",          -- another file name inside the folder
  -- alias = "idle", -- no sheet: show another animation instead (the folder needs no sheet.png then)
}
```

Factorio's own names are accepted as well, so the output of animation tools works as it is: `frame_count` (= frames),
`line_length` (= columns), `filename` (= file) and `animation_speed` (frames per tick, converted to `ticks`).
`direction_count`, `scale` and `shift` are ignored (a portrait plays the first direction; its size comes from the window).

Good to know:

* the window refreshes every 3 game ticks, so `ticks` below 3 plays at the same speed as 3 (20 frames per second);

* every frame has the same size; the window adapts to the frame's aspect ratio, so a tall character just works;
  its height is the **portrait size** (setting "Engineer: portrait size", or the - / + buttons of the window);
* you do not have to draw them all: leave a folder out (delete it) and the built-in placeholder is used, or make the
  folder `worried/animation.lua` contain just `return {alias = "idle"}` to show `idle` whenever the Engineer is worried;
* **your own animation** (for your own state in `states.lua`, or to alias to): make `custom/hammering/` with
  `animation.lua` + `sheet.png` and list the name in `custom/animations.lua`: `return {folders = {"hammering"}}`;
* `graphics/portrait/` holds the built-in fallback placeholders; edit the folders of `custom/` instead.

`custom/animations.lua` is an optional manual manifest (global `frame_size`, `aliases`, extra `folders`, or sheets
that live somewhere else). It overrides the folders of the same name.

## 2. Dialogues (`custom/dialogues.lua`)

`situation = { lines }`; one line is picked at random. A line is a string or
`{text = "...", animation = "happy", seconds = 3}`. Placeholders: `{status}`, `{tech}`, `{pct}`.
A situation in this file **replaces** the built-in lines of that situation. The list of situations is in the file.

## 3. States (`custom/states.lua`)

A state decides what the portrait shows right now (animation + status line). Register your own with
`interaction.register_state(id, priority, function(ctx) ... end)`; return `{animation = "...", line = "..."}` or nothing.
Remember: `require` only works at the top of a file in Factorio, never inside a function.

## 4. Packs: a separate mod that brings a character

Other mods can add animations and dialogues without editing this folder, so a "character pack" is just a mod:

```
my-engineer-pack/
  info.json        -- "dependencies": ["engineer-companion"]
  data.lua
  portrait/idle.png ...
```

`data.lua`:

```lua
data:extend{{
  type = "mod-data",
  name = "engineer-companion-pack-my-character",      -- the name MUST start with engineer-companion-pack-
  data = {
    frame_size = {width = 300, height = 450},
    animations = {
      idle = {file = "__my-engineer-pack__/portrait/idle.png", frames = 6, ticks = 14, caption = "Listening"},
      talk = {file = "__my-engineer-pack__/portrait/talk.png", frames = 4, ticks = 6},
    },
    aliases = {working = "talk"},
    dialogues = {                                      -- ADDED to the built-in lines
      greeting = {"Reporting for duty!"},
    },
    -- replace_dialogues = true,                       -- ... or replace them
  },
}}
```

Order of precedence (later wins): built-in, packs (alphabetical by name), the folders `custom/<name>/`, `custom/animations.lua`.

## 5. Sound

Put `.ogg` / `.wav` files in folders (`Sound/greeting/hello.ogg`, ...) and run `build_custom.py`; it copies them to
`sound/<group>/` and writes `sound/sounds.lua`. The Engineer plays the group named like the dialogue situation
(`greeting`, `farewell`, `research_finished`, `mode_follow`...) when it says a line of that situation, or the group of a
line's own `sound`: `{text = "Hello!", animation = "forest_talk", sound = "hello"}`. A group with several files plays a
random one. Restart Factorio after adding sounds.

`custom/folders.lua` is written by the same script: it lists every `custom/<n>/` folder that has an `animation.lua`.

## 6. The companion's body (its look in the world)

`body/body.lua` (written by `build_custom.py` from `frames/companion/`, same folders as build_mod.py: `idle/`,
`running/`, `mining/`, `idle_gun/`, `running_gun/`, optional `<name>_shadow/`) replaces the animations of the companion
entity only. The player keeps their own look. Delete `body/` and `graphics/body/` to go back to the vanilla look.
