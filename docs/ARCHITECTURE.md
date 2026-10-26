# Architecture

## Principles

- **One source of truth per phenomenon.** The ocean's waves live in one place
  (`Ocean.waves`) and are evaluated identically by physics (GDScript) and
  rendering (shader). Anything that floats reads the same surface it is drawn on.
  Time lives in `GameClock`, sky positions in `Astronomy`, world facts in `WorldConfig`.
- **Ask a query API, not a node.** Gameplay asks `Water.surface_height(x, z)`,
  `GameClock.current()`, `WorldConfig.current()` instead of holding references to
  a particular ocean or level. New kinds of water, terrain or worlds slot in
  behind the same questions.
- **Data in Resources, behaviour in systems.** Items, species, biomes, boats and
  character looks are `Resource` definitions in `src/data/`. A new boat or fish
  is a new `.tres`, not new code.
- **Cheap tricks, honestly labelled.** Most systems are known game-water hacks
  (Gerstner swell, spring buoyancy, a heightfield wave equation). Comments say
  what each one fakes and where its limits are.
- **GDScript first, native when measured.** Gameplay and glue are GDScript.
  Move a system into C++ (`native/`) only when the profiler shows it matters.
  Heavy per-cell work goes to the GPU (compute shaders), not to native code.

## Services and the world

- **Autoloads** (`src/autoload/`): `Events` (signal bus), `Game` (the running
  world, its config, clock and player), `Settings` (quality knobs), `Perf`
  (frame timings). See `src/autoload/README.md`.
- **`WorldConfig`** (`src/core/`): seed, latitude, the repeating calendar day,
  planet radius. A level assigns one (`open_ocean_world.tres`) and registers it
  with `Game.begin_world()` from `_enter_tree`, before any child's `_ready`.
  `seed_for("system")` gives each procedural system its own reproducible seed.
- **`WorldGrid`** (`src/core/`): square cells over XZ. The exploration map uses
  it now; terrain streaming, procedural generation and culling will share it.
- **Events** currently emitted: `day_changed` (clock), `player_water_changed`,
  `player_submerged_changed`, `player_drowned`, `boat_boarded` (player),
  `area_explored` (exploration), `view_mode_changed` (level).

## Systems

### Water (`src/systems/water/`)

`WaterBody` is the base for anything you can float, swim or dive in. It carries
the kind (ocean, lake, river), a priority for overlaps, a `BiomeDef`, and
chemistry (salinity, temperature with a simple thermocline, turbidity, a
placeholder floor depth), plus virtual queries: `contains_point`,
`surface_height`, `ripple_height`, `ripple_slope`, `floor_depth_at`, `flow_at`,
`density`. Bodies register themselves in a static list.

`Water` is the static query API over all bodies: `body_at(x, z)` (highest
priority containing the point), `surface_height` (`-INF` on dry land),
`depth_below_surface`, and `sample_at(pos)` which returns a `WaterSample`
(position, kind, depth, salinity, temperature, turbidity, biome, day and time,
and an empty `organisms` map for the future microbe system).

Buoyancy, the player and the camera all go through it, so a lake or river just
needs a `WaterBody` subclass. Buoyancy uses each body's density, so things ride
lower in fresh water.

#### Ocean (`src/systems/water/ocean/`)

| File | Role |
|---|---|
| `ocean.gd` / `ocean.tscn` | `Ocean extends WaterBody`: endless, the fallback everywhere. Owns the wave list, the wave time and `surface_height()`. Pushes uniforms to the water shader each frame. |
| `ocean_wave.gd` | One Gerstner component (direction, wavelength, amplitude, phase), editable in the inspector. |
| `ocean_surface.gd` | Builds the camera-centred polar mesh. Each vertex stores its local spacing so the shader can drop waves too short to resolve there (no far-field aliasing). |
| `water.gdshader` | Displaces the mesh, computes per-pixel normals (analytic Gerstner + ripples + procedural small waves, see below), refraction and depth absorption from the screen/depth textures, crest scattering and foam. Sky reflection and sun glints come from Godot's own lighting. |
| `ripple_sim.gd` / `ripple_sim.glsl` | Interactive ripples on the GPU (see below). |

**Height queries.** `surface_height(x, z, footprint, ripple_radius)` returns the swell
height above a world point. Gerstner moves water sideways, so it first finds the
undisplaced point that lands on `(x, z)` (three fixed-point iterations).
`footprint` low-passes the swell so a large hull ignores short waves.
`ripple_radius >= 0` adds the interactive ripples.

**Small waves.** No normal-map textures: the fragment shader sums up to 28
short travelling waves, from 7 m down to about 0.2 m (each 0.88x the last),
with directions spread around the wind and true deep-water speeds, so the
detail evolves like real ripples instead of sliding or tiling. Each wave uses
an exponentiated sine (sharper crests) and is shifted by the slopes of the
waves before it (domain warping), which breaks up the regularity of a plain
sum. Real chop is short-crested, so crest lines are curved and short: a broad,
slowly drifting warp (~1 m over tens of metres) bends them, and each wave comes
in packets, with an envelope that fades it along its crest after ~2 wavelengths and
along its travel after ~3. The envelope moves at the group velocity (half the crest
speed), so crests are born at the back of a packet and die at its front.
A floor keeps a little roughness between packets. They are evaluated at the
undisplaced position, so they ride the swell.
The loop stops at the first wave shorter than ~2.5 pixels, so distant water
costs only a few iterations and nothing aliases.

**Ripples.** A damped 2D wave equation on a 256 x 256 grid (0.3 m cells, ~77 m)
that scrolls with the player. Each physics frame:

1. Every node in the `ripple_sources` group reports a footprint (hull, box or
   disc) and how deep it sits in the swell.
2. The compute shader turns *changes* in that occupancy into displaced water.
   A moving hull pushes water out at the bow and lets it back in at the stern:
   that is the wake. Bobbing makes rings.
3. Two wave steps at 120 Hz propagate it; edges absorb.
4. The result goes to the water shader as a `Texture2DRD` (stays on the GPU) and
   back to the CPU with `texture_get_data_async` for physics, about a frame late,
   with no stall.

Objects read ripples on a ring just outside their own footprint, and compute
their displacement against the swell only. That breaks the feedback loop where
an object would sink into its own displacement trough.

### Atmosphere (`src/systems/atmosphere/`)

A single-scattering sky after Sebastian Lague's
[Solar System](https://github.com/SebLague/Solar-System) atmosphere, reworked from
his whole-planet post-process into a Godot sky shader for a camera on the surface.
Because it is the sky, it automatically drives water reflections, ambient light
and distance haze (the environment's fog uses `aerial_perspective = 1`, which
tints distant geometry with the sky colour in that direction).

| File | Role |
|---|---|
| `atmosphere_sky.gdshader` | Marches the view ray (16 samples bunched near the camera, dithered). At each sample it looks up the sunlight's optical depth in a baked table and accumulates the view ray's own. Draws the sun disc, reddened by the air in front of it. |
| `atmosphere.gd` | Bakes the optical-depth table (~50 ms at startup), pushes parameters, and sets the sun light's direction, colour and energy from the same maths, so sunsets light the world orange. Reads time from its `GameClock` and positions from `Astronomy`; answers sky questions (`night_amount()`, `moon_illumination()`). |
| `astronomy.gd` | Static: Julian date, sidereal time, the equatorial-to-world rotation, sun and moon directions and phase, all from `WorldConfig`, day and clock time. |

Model, as in Lague's: planet radius 1, density `exp(-h * falloff) * (1 - h)` with
`h` the height through the atmosphere 0..1, and scattering `(400 / wavelength)^4 * strength`.

Changes from his version:
- **Proportions.** His atmospheres are 32% of the planet's radius, tuned for
  viewing from orbit. From the ground that gives either a milky zenith or weak
  sunsets. The defaults use a 10% shell and 440 nm blue.
- **View-ray optical depth is summed** along the march instead of taken as
  differences of baked values. That is exact here and removes banding in thin atmospheres.
- **Ozone absorption** (Earth's ratios) keeps twilight blue instead of olive.
- **Haze (Mie scattering):** aerosols near the surface with a forward-scattering
  phase function give the warm glow around a low sun. The lookup has a second
  channel for them. The sun disc is kept dim enough that its colour survives tone mapping.
- **Tuned for vivid sunsets:** stronger scattering (30) for a redder horizon,
  more ozone (2.2x Earth's) for a deeper blue above it, and more haze (2.5).
- **High aerosol layer:** a thin Gaussian layer of stratospheric aerosol (third
  lookup channel). After the sun sets below, it still catches reddened light,
  and that light comes to you through blue sky. On its own it mostly warms the
  sky, so a **stylised twilight glow** (`twilight_glow`, `twilight_tint`) adds
  the rose-violet band above the sunset point while the sun is 1-6 degrees down.
  The clouds pick up a muted version of it; their sunset light is pulled 35%
  toward grey (`cloud_desaturate`) so they don't look cartoonish.
- **Every sunset differs:** each day draws its haze, haze phase, high aerosol,
  ozone, scattering strength, and twilight glow strength and hue from `WorldConfig.seed_for("sky:<day>")`
  (`sunset_variety` scales it, 0 = identical). The lookup is re-baked once a day
  at midnight. Day 0 uses the tuned defaults.
- The environment's colour adjustment adds saturation (1.3) on top of the
  Filmic tone mapper, which otherwise greys out twilight colours.

### Astronomy and the night sky

Every day is the same day: by default the 2026 winter solstice at 35 degrees
north (`WorldConfig.day_jd`, `latitude`). The clock alone drives the sun and
stars, so they repeat exactly each day. The moon and planets move on:
`GameClock.day` counts days, and their orbits follow it.

- **Clock** (`src/systems/time/game_clock.gd`). A node in the level that ticks
  first each frame (`process_priority = -100`). It also tracks `total_hours`
  and `real_seconds`, saves to a dictionary and emits `Events.day_changed`.
  The game starts at noon. Daylight (sunrise to sunset, found from
  the astronomy) lasts `day_minutes` (15) of real time and the night
  `night_minutes` (5). Time eases from day speed to night speed through
  twilight, so the sunset glow lasts about a minute instead of rushing by. The
  night speed is solved numerically so the night still comes to exactly 5 minutes.
- **Moon** (`moon.gd`, `moon.gdshader`, `Planets.moon_direction`).
  Low-precision lunar theory: mean elongation, anomaly and argument of
  latitude, plus the three largest periodic terms, placed relative to the fixed
  sun. So the phase cycle is the real 29.5 days, it rises about 50 minutes
  later each day, and it is up by day for part of every month. It is drawn as a
  sphere lit by the actual sun direction (5x real size, so the phase is
  visible). By day it adds to the sky; at night it covers the stars. A
  `Moonlight` directional light scales with phase and altitude, so a bright
  moon lays a glitter path on the sea.

- **One rotation for everything.** `Astronomy.equatorial_to_world()` turns
  equatorial coordinates (right ascension, declination) into the local sky from
  local sidereal time and latitude. The sun, stars, planets and deep-sky
  objects all go through it. World axes: +X east, +Y up, -Z north.
- **Planets** (`planet_layer.gd`, `planet_layer.gdshader`): small coloured
  discs on their own layer at 2,450 m, in front of the stars, behind the moon
  (which can pass over them) and behind the clouds. They wander from day to day.
  The outer planets run their orbits faster than real
  (`WorldConfig.outer_planet_pace`: 1 = about the moon's 13 degrees a day, 0 =
  real), so they visibly cross the constellations; the Earth keeps the real
  calendar, so their yearly retrograde loops stay gentle.
  Mercury and Venus are turned to keep their real angle from the frozen sun,
  so they never stray from it.
- **Orbits** (`planets.gd`): Keplerian orbits from JPL's approximate
  elements, Kepler's equation solved per body. Checked against the 2020
  Jupiter-Saturn conjunction and the 2020 Mars opposition (`tests/smoke_test.gd`).
- **Stars** (`starfield.gd`, `starfield.gdshader`): all 8,404 naked-eye stars
  of the Yale Bright Star Catalog plus the 110 Messier objects, as one
  `MultiMesh` draw. Stars are white points, all the same size; brightness follows
  their real magnitudes with one uniform boost.
  Messier objects are grey ellipses at their true angular size. At night the air
  doesn't dim anything; it only adds a slight shimmer that grows toward the horizon.
- **Data:** `tools/build_star_catalog.py` builds `bright_stars.tres`. Sources and
  licences are in `docs/THIRD_PARTY.md`.

### Buoyancy (`src/systems/buoyancy/buoyancy.gd`)

A component node under any `RigidBody3D`. Each `Marker3D` child is a probe that
pushes up with `rho * g * (area / probes) * depth`. The force is one-sided (no
pull out of the water) and capped at `max_depth` (fully submerged). Drag is taken
against the water's own vertical velocity. Probes at the hull corners give pitch
and roll for free. Place probes in the editor to tune any floating object.

The same component optionally registers the body as a ripple source.

### Camera (`src/systems/camera/player_camera.gd`)

`PlayerCamera` has two modes, toggled with F5; the game starts in first person.
Third person orbits the target and never dips below the water surface. The view
stays wherever you leave it; aboard a boat it turns with the boat
(`turn_with_target`), so a look over the side stays a look over the side. The
player's body faces where the camera looks; aboard, only the body turns, never
the boat. First person sits at the
player's head (the model is hidden so you don't see out through it) and looks
along the same yaw and pitch; it follows the head down if you sink.

`zoom` divides the field of view (from `base_fov`) and slows mouse aim, ready
for a spyglass or telescope. The starfield already sizes its points from the
camera's pixel angle, so stars stay points when magnified.

### Inventory (`src/systems/inventory/inventory.gd`)

One component for every container: a hand (1 slot), the knapsack (8), a boat's
hold (from its spec), a research bench. Slots hold `ItemStack`s (an `ItemDef`,
a count and per-instance data such as a jar's `WaterSample`). Stacks merge up to
`max_stack`; `accepts_tags` restricts what fits. Saves to a dictionary.

### Exploration (`src/systems/exploration/exploration_tracker.gd`)

Marks `WorldGrid` cells (50 m) within `reveal_radius` (250 m) of the player as
explored, emits `Events.area_explored`, and saves to a dictionary. The player
map will draw from it; it never moves anyone.

### Performance (`src/systems/performance/`, `Perf`, `Settings`)

`QualitySettings` holds the knobs systems read when they build: render scale
(applied to the viewport by the level), shadow distance, ocean mesh rings and
segments, cloud and puff counts, and detail and far distances for future LOD and
culling. `Perf` keeps smoothed frame time and render counts.

## Data (`src/data/`)

| Schema | Holds |
|---|---|
| `ItemDef` / `ItemStack` | Anything carried: tags (`tool`, `rod`, `net`, `trap`, `sample_container`, `optic`, `wearable`, `catch`) and free-form stats (`magnification`, `breath_seconds`, ...). |
| `SpeciesDef` | An organism: kind (fish, invertebrate, plant, microbe), catch methods (rod, net, trap, sample), habitat (waters, depth, salinity, temperature, active hours), size, schooling, rarity. |
| `BiomeDef` | A habitat (`open_ocean.tres` so far): medium, depth range, map colour, species list, `species_for(depth, hour, water)`. |
| `BoatSpec` | Handling, speed and cargo: mass, size, thrusts, steering, drags, bow lift, lean, hold slots and weight. `small_motorboat.tres` reproduces the original boat. |
| `CharacterTraits` | Height, build, skin, hair and clothing colours, free-form features. `generate(rng)` for NPCs; `apply_to(model)` dresses the capsule model. |

### Clouds (`src/systems/clouds/`)

Highly stylised cumulus made of round puffs ("dots"): 40 small puffs per cloud,
40,000 in one `MultiMesh`. Puff size scales with the puff count so a cloud's
overall size stays put when the count changes. The CPU lays them out once; the vertex shader does the rest:

- **Wind** drifts the whole layer, which wraps around the camera (24 km square,
  1.3 km up) and shrinks clouds away near the wrap edge instead of popping.
- **Life cycle.** Each cloud cycles through condensing, maturing and evaporating
  (`life_seconds`), with a fresh random strength each cycle. Some cycles never
  form (`coverage`). Base puffs condense first and the tower builds last, so
  clouds grow upward and evaporate from the top down. Puffs appear by growing,
  not fading, so they stay crisp opaque dots with correct overlap (alpha scissor).
- **Depth squeeze.** Most clouds lie far beyond the camera's 4 km far plane.
  The vertex shader pulls each puff in along its line of sight (scaled to
  match, so it looks the same) with a monotonic squeeze into 2.2 km. That keeps
  puffs ordered, unclipped and in front of the star and moon spheres. (Clipping
  is by view depth, so puffs in the middle of the view were cut before ones
  at the edges.)
- **Lighting.** Three-band toon shading of each puff as a sphere, darker toward
  the cloud base. The sunlight colour is computed per frame for the cloud
  layer's height, which still sees the sun a little after sunset at sea level.
  Each puff's direct light fades smoothly from a sun about 7 degrees up until
  the planet's shadow passes that puff (a puff h metres up sees the sun until
  it is sqrt(2h/R) below the horizon), so bases darken first and tops glow last.
  That light is kept fully saturated (stylised), so clouds glow orange and pink
  through the afterglow, then go slate-grey.

## Entities

- **Player** (`CharacterBody3D`). Custom swim physics with one buoyancy probe at
  the chest, slightly denser than water. Treading and swimming are force-limited
  kicks toward the surface. Boards boats by distance. Has `LeftHand`,
  `RightHand` and `Knapsack` inventories; `breath_capacity()` adds gear's
  `breath_seconds` (the snorkel and scuba hook); `head_under` and `water` track
  where they are. `PlayerStats` keeps distances swum and boated, time in and
  under water, deepest dive, waters and biomes visited.
- **Boat** (`RigidBody3D` + `Buoyancy`). Thrust, keel drag (easy forward, hard
  sideways), a rudder that bites with speed, bow lift, lean into turns, all
  scaled by its `BoatSpec`. `BoatStation` markers (helm, perch, cargo, research)
  say where the player stands to do things; `station(kind)` finds them. The
  `Cargo` inventory is the hold. Tracks odometer, hours under way and top speed.
- **Crate** (`RigidBody3D` + `Buoyancy`, one probe). Passive floater that rides
  and gets pushed by wakes.

## Physics layers

| Layer | Name | Who |
|---|---|---|
| 1 | world | rigid bodies: boats, props, terrain |
| 2 | characters | the player (and later NPCs) |

Characters sit on their own layer and mask only `world`. They are blocked by
hulls and props but never push them: a kinematic body has effectively infinite
mass, and any overlap would launch the rigid body.

## Adding things

- **A new floating object:** a `RigidBody3D` with a collision shape, a `Buoyancy`
  child, and one or more `Marker3D` probes under it. Set `waterplane_area` and
  `max_depth` from the hull's size. Pick a ripple shape if it should make waves.
- **A new level:** a scene under `src/world/<name>/` with a `WorldConfig`, a
  `GameClock`, `Ocean` (if it has sea), a `WorldEnvironment`, a sun and the
  entities it needs. Its script calls `Game.begin_world(self, config)` in
  `_enter_tree` and `Game.end_world(self)` in `_exit_tree`.
- **A lake or river:** extend `WaterBody`, set `kind`, `priority` and chemistry,
  and override `contains_point` and `surface_height` (and `flow_at` for a river).
- **A boat:** a `BoatSpec` `.tres`, a hull scene with `Buoyancy` probes,
  `BoatStation` markers and a `Cargo` inventory.
- **An item or species:** a new `ItemDef` / `SpeciesDef` `.tres` in `src/data/`;
  add species to a `BiomeDef`.
- **A minigame:** see `src/minigames/README.md`.

Planned systems and the hooks they build on are listed in `docs/ROADMAP.md`.
