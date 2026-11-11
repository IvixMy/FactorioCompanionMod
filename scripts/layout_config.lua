-- Tunable values for the steam power plant layout. Edit this file (no other code changes needed),
-- save, and reload the mod / game.
--
-- Everything marked "nil = auto" is normally worked out from the game's prototypes and the shore.
-- If a layout comes out wrong, run  /engineer-connections  in the game: it prints the raw and the
-- computed fluidbox connection points of the offshore pump, boiler and steam engine. Compare them
-- with what you see in the game and put the correct values here.
--
-- Offsets are in tiles, relative to the entity's centre (x to the right, y DOWN), for an entity
-- facing NORTH. They point at the centre of the NEIGHBOURING tile a pipe must occupy to connect.
-- ("direction" numbers: north = 0, east = 4, south = 8, west = 12 in Factorio 2.x.)

local D = defines.direction

return {
  -- Distances ----------------------------------------------------------------------------
  water_clearance = 3,        -- boilers/engines keep at least this many tiles away from water
  min_pipes       = 3,        -- shortest pipe run between the pump and the first boiler
  max_pipes       = 30,       -- longest pipe run
  pump_search_radius = 120,   -- how far from the companion to look for water (tiles)

  -- Offshore pump -------------------------------------------------------------------------
  -- Where the first pipe goes, relative to the pump centre, for each pump direction.
  -- nil = auto: the tile right behind the pump on the land side (what a player would do).
  -- Example (pump output towards the south when the pump faces north):
  --   pump_output_offset = {[D.north] = {0, 1}, [D.east] = {-1, 0}, [D.south] = {0, -1}, [D.west] = {1, 0}},
  pump_output_offset = nil,

  -- Boiler (facing north) -----------------------------------------------------------------
  -- nil = auto (read from the prototype). Otherwise:
  --   water_west = neighbour tile of the water connection on the boiler's WEST end
  --   steam      = neighbour tile of the steam output
  -- Vanilla boiler (3x2): water_west = {-2, 0.5}, steam = {0, -1.5}
  boiler = nil,
  -- boiler = {water_west = {-2, 0.5}, steam = {0, -1.5}},

  -- Steam engine --------------------------------------------------------------------------
  engine_length = nil,        -- tiles along its axis; nil = auto (vanilla: 5)

  -- How stored fluidbox positions are interpreted: how far (tiles) a stored connection position
  -- must be moved outwards to reach the neighbouring tile. nil = auto-detect from the steam engine.
  fluidbox_delta = nil,
}
