# Roadmap

Planned systems, and what is already in place for each. "Hooks" are the
existing classes, fields and signals a system should build on rather than
reinvent. Nothing here is implemented yet beyond those hooks.

## Performance

**Culling (frustum and distance).** Godot already frustum-culls every
`VisualInstance3D`; the work is for huge instanced fields (fish schools, kelp,
coral) and terrain chunks.
- Hooks: `QualitySettings.detail_distance` / `far_distance`; `WorldGrid` for
  chunk-level culling; `Perf.objects_drawn` / `draw_calls` to measure.
- Note: the ocean surface sets a custom AABB on purpose (shader
  displacement), so it is never culled.

**Resolution that scales with distance.**
- Hooks: `QualitySettings.render_scale` (applied by the level through
  `Settings.apply_to_viewport`); the ocean surface already spaces its vertices
  by distance and the shader drops waves too short for a ring. Terrain and props
  should follow the same pattern: detail from distance to the camera, with
  `Perf.frame_ms` to drive dynamic resolution.

## Landscapes and objects: SDFs, fractals and meshes

(Heightfield terrain, lakes and rivers now exist: see ARCHITECTURE, Terrain.
What follows is for caves, overhangs, coral and props.)

- Hooks: `WorldGrid` (chunk keys), `WorldConfig.seed_for()` (per-system seeds),
  `QualitySettings` distances (LOD bands).
- Plan: a `src/systems/terrain/` with a height/SDF query API shaped like
  `Water` (`Terrain.height_at`, `Terrain.sdf`), so buoyancy, the camera and the
  player can ask for ground the same way they ask for water. Meshing (marching
  cubes, dual contouring or raymarched SDF in a shader) stays behind that API.
  `WaterBody.floor_depth_at()` will read the terrain instead of `floor_depth`.

## Procedural generation

**Ocean floor and undersea biomes** (coral reefs, kelp forests, tidepools, root mazes).
- Hooks: `BiomeDef` (medium, depth range, map colour, species), `WaterBody.biome`,
  `Water.sample_at().biome_id`, `WaterBody.floor_depth_at()`.
- Plan: a biome field over `WorldGrid` cells chosen from depth, temperature and
  shore distance, seeded by `WorldConfig.seed_for("biomes")`. `body.biome`
  becomes the default; a `biome_at(x, z)` query takes over where the field exists.

**Land: continents with rivers, archipelagos, volcanic chains.**
- Hooks: `WaterBody.Kind.RIVER` / `LAKE`, `priority`, `contains_point`,
  `flow_at`; `WorldConfig.world_seed` and `planet_radius_m`.
- Plan: generation writes terrain and spawns `WaterBody` subclasses for lakes and
  rivers (a river body returns its channel in `contains_point` and its current
  in `flow_at`).

## Fish and fishing (rods, nets, traps)

- Hooks: `SpeciesDef` (kind, catch methods, habitat, active hours, size, schooling,
  rarity), `BiomeDef.species_for(depth, hour, water)`, `ItemDef` tags
  (`rod`, `net`, `trap`, `catch`), `Inventory`, `Player.held()`, `BoatStation`
  `PERCH`, `GameClock.time_of_day`, `Atmosphere.night_amount()` and
  `moon_illumination()` (for night and moon-phase feeding).
- Plan: a spawner per area queries `species_for` and keeps schools within
  `detail_distance`. Each gear type is a minigame under `src/minigames/` that
  emits `finished(result)`, and the result goes into an `Inventory`.

## Spyglass and telescope

- Hooks: `PlayerCamera.zoom` (divides the FOV and slows aim); the starfield sizes
  points from the camera's pixel angle; the star catalogue already has all 8,404
  naked-eye stars, the 110 Messier objects with true angular sizes, and the
  planets; `ItemDef` tag `optic` with stat `magnification`.
- Plan: holding an optic sets `camera.zoom`. Deeper star catalogues and
  higher-detail Messier sprites load once magnification passes a threshold.
  Far terrain uses higher LOD inside the narrowed frustum.

## Snorkel and scuba

- Hooks: `Player.head_under`, `head_depth()`, `breath_capacity()` (adds gear
  `breath_seconds`), `gear_stat()`, `Events.player_submerged_changed`,
  `WaterBody.turbidity` / `temperature_at()`, `PlayerStats.max_depth_m`.
- Plan: snorkel = surface breathing while face-down near the surface; scuba =
  a large `breath_seconds` plus neutral buoyancy control and depth limits.
  Underwater visuals (fog from turbidity, light falloff) key off `head_under`.
  Worn gear will need a slot beyond the hands; `gear_stat()` is where it plugs in.

## Inventory: two hands and a knapsack

- Hooks: `Player.left_hand`, `right_hand` (1 slot each), `knapsack` (8),
  `Inventory` (stacking, filters, mass, save), `ItemDef.two_handed`.
- Plan: the UI under `src/ui/`; an equip action swaps hand and knapsack slots.

## Character generator and feature selector

- Hooks: `CharacterTraits` (height, build, colours, free-form `features`),
  `generate(rng)` (reproducible NPCs), `apply_to(model)`, `Player.traits`,
  `default_player.tres`.
- Plan: a creator UI edits a `CharacterTraits`; NPCs get theirs from
  `generate()` with `WorldConfig.seed_for("npc:<id>")`. A real character model
  replaces the capsules and reads the same fields.

## Boats

- Hooks: `BoatSpec` (handling, speed, cargo), `BoatStation` (`HELM`, `PERCH`,
  `CARGO`, `RESEARCH`, each with an optional inventory), `Boat.station(kind)`,
  `Boat.cargo`, the odometer, hours under way and top speed,
  `Events.boat_boarded`.
- Plan: each boat is a spec plus a hull scene. Walking around on deck replaces
  the snap-to-helm; interacting at a station hands control to that station's
  activity (steering, fishing, the microscope).

## Player map

- Hooks: `ExplorationTracker` (explored `WorldGrid` cells, save/load),
  `Events.area_explored`, `BiomeDef.map_color`.
- Plan: a map UI that paints explored cells (by biome colour, later terrain).
  No teleporting: the map only reads.

## Water samples and the microscope

- Hooks: `Water.sample_at(pos)` gives a `WaterSample` (kind, depth, salinity,
  temperature, turbidity, biome, day and time, and an empty `organisms` map);
  `ItemStack.data` can carry it in a jar (`sample_container` tag);
  `SpeciesDef.Kind.MICROBE` with `Catch.SAMPLE`; `BoatStation.RESEARCH`.
- Plan: filling a jar stores a sample in the stack's data. The microbe system
  fills `organisms` from the biome's microbe species and the sample's conditions.
  The microscope is a minigame that views a sample.
