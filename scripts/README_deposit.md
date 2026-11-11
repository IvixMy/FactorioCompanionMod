# Deposit: surplus goes to free storage chests

New:     scripts/deposit.lua, scripts/storage_chests.lua, scripts/tasks/deposit.lua
Changed: scripts/tasks.lua (registers "deposit"), scripts/planner.lua, scripts/progress.lua (one hook each)

## What it does
Items that are in the requests window and above their MAX are carried to a free storage chest (only the part above MAX).
Items that are not in the requests list are never touched (build materials, mined stuff, salvage...).

## What is a "free storage chest" (scripts/storage_chests.lua)
A plain chest, or a logistic chest in storage / passive-provider mode, where
 * no inserter (built OR ghost) picks up from it or drops into it (assembler output, train stop in/out, lab feed...)
 * no mining drill outputs into it, no loader faces it
 * it is not inside a zone managed by the objectives
The check is repeated when the companion arrives, so an inserter built in the meantime cancels the trip.

## When it runs
Only when the companion is idle: planner.lua after the "top up" restock found nothing, progress.lua when the
objectives are blocked / done. Never while a task or a craft is running. A trip starts when an item is 25% of its MAX
above it, or the inventory has fewer than 2 free stacks (deposit.MIN_TRIP_SHARE). Chests that are in use or full are
skipped for 30 minutes (BLOCK_TIME); with no chest at all it retries every 30 s (IDLE_RETRY).

## Switches
deposit.ENABLED = false              -- turn it off
deposit.RADIUS (default MINE_RADIUS) -- how far it looks for a chest
Follow-and-build mode only uses chests near the player (same rule as the restock).
