# Bulk building + editable carried requests

Changed: scripts/common.lua, scripts/planner.lua, scripts/loadout.lua, scripts/interaction.lua
New:     scripts/requests.lua

## 1. Builds grab ALL the material in one trip
planner.lua adds up what every visible ghost / upgrade needs per item (90 walls -> 90 stone-wall) and the fetch
task takes all of it from the chest (as far as the chest has it and the inventory has room, keeping
common.FETCH_KEEP_FREE_STACKS = 2 stacks free). If the items must be crafted, the whole amount is queued when the
materials allow it. NEAR_GHOST_LIMIT / FAR_GHOST_LIMIT went from 50 / 200 to 500 / 1000, so big blueprints are
counted completely. Set common.FETCH_ALL = false to get the old "~10 ghosts per visit" behaviour.

## 2. Carried items are now a request table the player edits
No more fixed items / amounts (and no dependency on the "ec-loadout-<x>" mod settings): the "Requests" button of the
talk window opens a window like the player's personal logistics: per slot an item, a MIN and a MAX.
 * an item below MIN starts a restock trip; the trip fills EVERYTHING that is below its MAX
 * the "has N" label is red while the item is below MIN
 * the first time, the old settings (if they exist) are imported once as a starting table
 * to open it from elsewhere: require("scripts.requests").toggle(player)

## control.lua hooks (control.lua is not in the zip, so not applied)
    local requests = require("scripts.requests")   -- at load time, not inside a handler
    script.on_event(defines.events.on_gui_elem_changed, function(e) requests.on_elem_changed(e) end)
    script.on_event(defines.events.on_gui_text_changed, function(e) requests.on_text_changed(e) end)
If control.lua already handles these events, call the two functions from inside the existing handler.
Clicks already work: the buttons use tags.ec_interact, which control.lua routes to interaction.handle_click.
