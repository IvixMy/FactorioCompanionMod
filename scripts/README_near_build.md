# Near-build: build nearby ghosts from the logistics, craft what is missing

Changed files: scripts/common.lua, scripts/supply.lua, scripts/planner.lua

## Hook (control.lua - not in the zip, so not applied)
Where the follow loop handles mode == "follow_build", call this each tick instead of the player-inventory build:

    local planner = require("scripts.planner")   -- must be required at load time, not inside the handler
    ...
    if mode == "follow_build" then
      if planner.near_build_step(player, data) then return end  -- busy: do not steer, the task is walking
      -- otherwise continue with the normal follow movement
    end

Also run `crafting.tick(data)` every tick (as auto-build already does) so queued crafts finish.

## What it does
1. Looks only at ghosts within NEAR_BUILD_RADIUS (15) of the PLAYER.
2. Item carried -> build. In a chest / the logistic network -> fetch, then build.
3. Otherwise crafts it from carried + chest + network materials (crafting.lua, recursive), then builds.
4. Network support (common.USE_LOGISTIC_NETWORK = true): network contents count as supply, requester chests
   are never raided, the pickup chest comes from network.select_pickup_point.
   Set it to false to get the old chest-scan behaviour.

## Deconstruction (tasks/deconstruct.lua) - takes the same time as a player
The entity is MINED with the engine's own hand-mining (mining animation), so it takes
mining_time / mining speed whether it is a tree, a rock or a building, and the real mining products go
into the inventory. If the engine has not finished after the expected time + 50%, it is mined by script, so
it is never faster than a player. Salvage bookkeeping + stash: scripts/salvage.lua (storage / passive-provider
logistic chests only). Switch off with common.DECONSTRUCT = false. Tiles are not handled.

## Upgrades (tasks/upgrade.lua)
Entities marked for upgrade: the item of the UPGRADE TARGET is supplied exactly like a ghost's (carried -> chest /
logistic network -> crafted), then the entity is replaced (entity.apply_upgrade(), fast-replace as fallback), the
old building's item goes back into the inventory (counted as salvage). Switch off with common.UPGRADE = false.

Planner order: deconstruct near -> build near -> upgrade near -> far build -> far upgrade -> far deconstruct.
