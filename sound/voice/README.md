# Voice lines

Each situation has a folder here. `crafting`, `meet`, `thinking` and `low_power` hold the real lines. `idle`, `working` and `enemy_attack` still hold PLACEHOLDER tones (`line1.ogg`): replace them with real lines (.ogg).

| situation      | played when                                                                 |
|----------------|-----------------------------------------------------------------------------|
| `idle`         | it has nothing to do and stands still for a while                           |
| `meet`         | it sees you again after a long time without seeing you                      |
| `working`      | it starts a job after a while without one                                   |
| `crafting`     | it starts hand-crafting                                                     |
| `thinking`     | a new research starts                                                       |
| `low_power`    | the machines around you cannot get enough power (heard anywhere)            |
| `enemy_attack` | several enemy units are near you (heard anywhere)                           |

To use your own files: put them in the folder (any name) and list them in `sound/sounds.lua`:

    voice_idle = {
      "__engineer-companion__/sound/voice/idle/hello1.ogg",
      "__engineer-companion__/sound/voice/idle/hello2.ogg",   -- several files: a random one each time
    },

Restart Factorio after changing files or the list. New situations: `custom/voices.lua`.
Other mods / scripts can play a line with `remote.call("engineer_companion_voice", "say", player_index, "meet")`.
