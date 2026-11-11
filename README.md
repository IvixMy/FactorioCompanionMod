# FactorioCompanionMod

A Factorio **2.1+** mod that adds a **Companion**: a helper that follows you around, builds for you, and, in **Base Development** mode, runs a good part of your base on its own. The Companion is the main feature of the mod.

There is no Space Age integration yet: the mod does not add anything specific to Space Age content.

**Current version: 0.20.1** (the next planned version bump is 0.30, which will not happen for a while).

## Getting started

1. Open the Companion menu with the button at the **top left** of the screen.

<img width="1920" height="1080" alt="debugmenu" src="https://github.com/user-attachments/assets/cf0387ec-3565-48e5-b03b-fd6ef789a012" />


2. Click **Summon**.

<img width="1920" height="1080" alt="summon" src="https://github.com/user-attachments/assets/4ddb19b4-bfab-4f92-b458-9651951796a5" />


3. Pick a mode. For the best experience, choose **Base development**.

<img width="1920" height="1080" alt="basedevelopment" src="https://github.com/user-attachments/assets/1aab13fd-9c77-4493-a2f4-044f78b8d94a" />



### Naming your Companion

You can name the Companion anything you like in **Settings → Mod settings → Map → Companion name**. The name changes both over the Companion's head on the map and in the displayed names in the interface.

## Recommended use

**Right now the best way to run the Companion is Base Development mode, from the very beginning of the game up to the mid game in Space Age.** That is the stage the mod is designed and tuned for. The other modes are simple helpers; Base Development is where the mod's main work happens.

## Compatibility and known limitations

### Tested with

| | Status |
|---|---|
| Factorio version | Only **2.1.23** has been tested. Other versions are untested and may not work. |
| Surfaces (Space Age) | Only **Nauvis** has been tested. Other planets and surfaces are untested. |

### Construction robots

The Companion works alongside construction bots. When a ghost is already assigned to be built by a bot, the Companion does not go through the effort of building it itself and leaves it to the bot.

### Known issues

- **Performance around the mid game.** As the base grows large, performance drops. This is a known problem that needs to be fixed. The suspected cause is **pathfinding over large distances** (roughly 500 to 1000 units across the base). The same long trips are also where the Companion is most likely to get stuck. See [Fast travel](#fast-travel-for-long-trips) for the current mitigation.

## Fast travel for long trips

To reduce the pathfinding cost of long trips, and to keep the Companion from getting stuck on them, there is a per-player setting:

**Settings → Mod settings → Per player → Companion → "Companion: fast travel for long trips"**

When it is on and the Companion has a long way to go, it does not walk the whole route:

1. It works out an **estimated time of arrival** (ETA) to its goal point.
2. It **waits in place** while the ETA counts down to 0.
3. It **teleports** to its goal location.

This is a mitigation, not a fix for the underlying performance problem. Walking still applies to shorter trips.

## Modes

Open the menu with the Companion button (top bar) or the `ec-toggle-menu` hotkey. The mode is chosen per player.

| Mode | What it does |
|---|---|
| **Follow only** | Follows you and does nothing else. |
| **Follow and build nearby ghosts** | Follows you and builds ghosts near itself, using items from **your** inventory. |
| **Wait in place** | Stays where it is. |
| **Base development** | Works on its own: see below. |

The optional **Defend me** checkbox makes the Companion shoot the enemy closest to you while it follows you (follow modes only). It borrows a spare gun and ammo from your inventory and returns them when you untick the box or dismiss it.

---

## Base Development Mode

In this mode the Companion stops following you and develops the base by itself. It builds ghosts **anywhere on the surface**, gets the items from **your chests**, crafts what is missing, keeps machines fuelled, and works on your objectives. When it has nothing to do, it wanders around the buildings it placed.

### How it works

Every tick the Companion is in one of three states:

1. **Running an action.** If you started a manual action (e.g. deploying miners) from the menu, that runs first.
2. **Running a task.** Otherwise it continues its current task.
3. **Planning / idle.** If it has no task, the planner looks at the ghosts on the map (about every half second) and picks the next task. If there is nothing to do, it roams.


- **Fetch:** takes the needed items out of your chests (the supply index tracks what each chest holds).
- **Craft:** anything missing is hand-crafted in the background. Crafting runs in every mode, not just this one.
- **Build:** revives ghosts and records what it placed, so it knows where to roam and which objectives progressed. Ghosts that a construction bot has already been assigned to are left to the bot.
- **Upkeep:** keeps machines fuelled. While it is holding something for upkeep, the planner waits.
- **Idle:** wanders randomly within a set radius of buildings it placed. If it has not built anything yet, it just stands still.

Trips between these steps can be long in a big base. That is where [fast travel](#fast-travel-for-long-trips) comes in.

### Setting it up

1. Put the items you want used in **chests** (the Companion fetches from chests, not from your inventory in this mode).
2. Place ghosts, by hand or from blueprints.
3. Select **Base development** in the Companion menu.
4. Watch the **Status** line in the menu to see what it is doing (current task, crafting, navigation notes).
5. For big bases, consider turning on **fast travel for long trips** in the per-player mod settings.

### Actions (menu: "Action")

Actions are one-off jobs you start with **Run**. Starting one while in another mode switches the Companion to Base development. Some actions are marked *(coming soon)* and cannot be started yet.

Actions that build a larger structure can be given a blueprint: pick one up (or a book with the right blueprint active) and press **Assign blueprint from cursor**.

### Ore assignment

Pick an ore in the **Assigned ore** dropdown and press **Find best patch**. The Companion scans the area you have charted on the current surface and prefers very large patches, then the ones closest to spawn.

### Building zones

When the Companion plans a larger build (a science factory, a belt factory, ...), it reserves a **zone**. The menu lists every zone with its progress (`built/total`), whether it comes from a blueprint, and its location.

- **Erase** deletes the zone's unbuilt ghosts and frees the area. Buildings already standing stay. The Companion may plan the same thing again somewhere else.
- **Erase all zones** asks for a second click to confirm.

### Zone blueprints

Under **Assign blueprints...** you can give a zone your own blueprint (pasted string or taken from your cursor) instead of the Companion's built-in layout.

- Takes effect the **next time** the Companion plans that zone.
- A zone that is already placed keeps what it has. Erase it first to rebuild from a new blueprint.
- Raw ingredients that no machine in the blueprint produces are put into the machines by hand.
- **Clear** returns that zone to the Companion's own layout.

### Talk and objectives

The **Talk** button (or `SHIFT+F`, or `E` while pointing at the Companion) opens the conversation window, where you can give requests and objectives. The Companion also comments on events, such as finished research.

---

## Other controls

| Control | Effect |
|---|---|
| **Call to me** | Teleports the Companion next to you and cancels its current task. |
| **Summon / Dismiss** | Spawns or removes the Companion. Dismissing returns everything it carries to your inventory. |
| `/engineer` | Summon or dismiss from the console. |
| `/engineer-connections` | Prints fluidbox connection points of the offshore pump, boiler and steam engine (for tuning `scripts/layout_config.lua`). |

The Companion's name can be changed in the map settings (see [Naming your Companion](#naming-your-companion)).

## Things to know

- **Base development** takes items from chests; **Follow and build** takes them from your inventory.
- Changing the mode cancels the current task. Leaving Base development also cancels the running action.
- The Companion charts and generates terrain around itself while it works.
- It cannot be selected with the mouse, so it never blocks your aim.

## Code layout

```
control.lua              events, GUI, mode switching
scripts/common.lua       shared constants and movement helpers
scripts/supply.lua       chest contents index
scripts/crafting.lua     background hand-crafting
scripts/planner.lua      decides the next task from the ghosts on the map
scripts/tasks.lua        task registry (scripts/tasks/*.lua: fetch, build, ...)
scripts/actions.lua      action registry (scripts/actions/*.lua: deploy_miners, ...)
scripts/prospecting.lua  ore scanning
scripts/blueprints.lua   blueprint storage for actions
scripts/bpslots.lua      blueprints assigned to zones
scripts/zones.lua        building zones
scripts/upkeep.lua       keeping machines fuelled
scripts/defense.lua      "Defend me"
scripts/pathing.lua      navigation around obstacles
scripts/interaction.lua  Talk window, dialogues, notifications
```

## Status

Version 0.20.1. Work in progress: some actions are still stubs, and large-base performance is the main open issue (see [Known issues](#known-issues)). Version 0.30 is not planned any time soon.
