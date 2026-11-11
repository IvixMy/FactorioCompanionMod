-- Sound groups: {group = {files}}. Each group is the sound prototype "ec-sound-<group>" (data-final-fixes.lua).
-- state_change        played (with a short "noise" animation) whenever the Engineer's state changes in the Talk window
-- state_<state id>    optional: a group for ONE state (state_working, state_blocked, state_idle...) beats state_change
-- A group with several files plays a random one. Restart Factorio after adding files.
return {
  -- Voice lines of the situations outside the Talk window (scripts/voice.lua): voice_<situation id>. Replace the
  -- placeholder files, or list more files: a group with several files plays a random one. Restart Factorio after.
  voice_idle         = {"__engineer-companion__/sound/voice/idle/line1.ogg"},
  voice_meet = {
    "__engineer-companion__/sound/voice/meet/meet.ogg",
    "__engineer-companion__/sound/voice/meet/meet1.ogg",
    "__engineer-companion__/sound/voice/meet/meet2.ogg",
  },
  voice_thinking = {
    "__engineer-companion__/sound/voice/thinking/thinking.ogg",
  },
  voice_working      = {"__engineer-companion__/sound/voice/working/line1.ogg"},
  voice_crafting = {
    "__engineer-companion__/sound/voice/crafting/crafting.ogg",
    "__engineer-companion__/sound/voice/crafting/crafting1.ogg",
  },
  voice_low_power = {
    "__engineer-companion__/sound/voice/low_power/lowenergy.ogg",
  },
  voice_enemy_attack = {"__engineer-companion__/sound/voice/enemy_attack/line1.ogg"},
  state_change = {
    "__engineer-companion__/sound/state_change/blip1.ogg",
    "__engineer-companion__/sound/state_change/blip2.ogg",
    "__engineer-companion__/sound/state_change/blip3.ogg",
  },
}
