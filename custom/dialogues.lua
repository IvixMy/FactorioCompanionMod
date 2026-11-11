-- CUSTOM DIALOGUES (see README.md in this folder).
--
-- A situation listed here REPLACES the built-in lines of that situation. Each line is a string, or
-- {text = "...", animation = "happy", seconds = 3}. {status}, {tech}, {pct} are filled in where they make sense.
-- Restart is NOT needed for this file when you only change text, but load a save again to be sure.
--
-- Situations: greeting, farewell, status_idle, status_working, status_blocked, status_research, mode_follow,
-- mode_wait, mode_auto_build, nothing_special, research_finished, too_far, not_summoned
--
-- Example (remove the "--" to use it):
--
-- return {
--   greeting = {
--     "Boss! Finally.",
--     {text = "I was about to start without you.", animation = "worried"},
--   },
--   research_finished = {{text = "{tech} is done. Next?", animation = "happy", seconds = 15}},
-- }

return {}
