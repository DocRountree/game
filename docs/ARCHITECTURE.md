# Architecture

## Principles

- **One source of truth per phenomenon.** The ocean's waves live in one place
  (`Ocean.waves`) and are evaluated identically by physics (GDScript) and
  rendering (shader). Anything that floats reads the same surface it is drawn on.
- **Cheap tricks, honestly labelled.** Most systems are known game-water hacks
  (Gerstner swell, spring buoyancy, a heightfield wave equation). Comments say
  what each one fakes and where its limits are.
- **GDScript first, native when measured.** Gameplay and glue are GDScript.
  Move a system into C++ (`native/`) only when the profiler shows it matters.
  Heavy per-cell work goes to the GPU (compute shaders), not to native code.

## Systems

### Ocean (`src/systems/ocean/`)

| File | Role |
|---|---|
| `ocean.gd` / `ocean.tscn` | The `Ocean` node. Owns the wave list, the clock, and `height_at()`. Pushes uniforms to the water shader each frame. `Ocean.instance` is the global access point. |
| `ocean_wave.gd` | One Gerstner component (direction, wavelength, amplitude, phase), editable in the inspector. |
| `ocean_surface.gd` | Builds the camera-centred polar mesh. Each vertex stores its local spacing so the shader can drop waves too short to resolve there (no far-field aliasing). |
| `water.gdshader` | Displaces the mesh, computes per-pixel normals (analytic Gerstner + ripples + scrolling detail normal maps), refraction and depth absorption from the screen/depth textures, crest scattering and foam. Sky reflection and sun glints come from Godot's own lighting. |
| `ripple_sim.gd` / `ripple_sim.glsl` | Interactive ripples on the GPU (see below). |

**Height queries.** `height_at(x, z, footprint, ripple_radius)` returns the swell
height above a world point. Gerstner moves water sideways, so it first finds the
undisplaced point that lands on `(x, z)` (three fixed-point iterations).
`footprint` low-passes the swell so a large hull ignores short waves.
`ripple_radius >= 0` adds the interactive ripples.

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
| `atmosphere.gd` | Bakes the optical-depth table (~50 ms at startup), pushes parameters, runs the clock and the astronomy, and sets the sun light's direction, colour and energy from the same maths, so sunsets light the world orange. |

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

### Astronomy and the night sky

Every day is the same day: the 2026 winter solstice at 35 degrees north. The
clock alone drives the sun, stars and planets, so they repeat exactly each day.
Only the moon moves on: `Atmosphere.day` counts days, and the moon's orbit
follows it.

- **Clock.** The game starts at noon. Daylight (sunrise to sunset, found from
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

- **One rotation for everything.** `Atmosphere.equatorial_to_world()` turns
  equatorial coordinates (right ascension, declination) into the local sky from
  local sidereal time and latitude. The sun, stars, planets and deep-sky
  objects all go through it. World axes: +X east, +Y up, -Z north.
- **Sun and planets** (`planets.gd`): Keplerian orbits from JPL's approximate
  elements, Kepler's equation solved per body. Checked against the 2020
  Jupiter-Saturn conjunction and the 2020 Mars opposition (`tests/smoke_test.gd`).
- **Stars** (`starfield.gd`, `starfield.gdshader`): all 8,404 naked-eye stars
  of the Yale Bright Star Catalog plus the 110 Messier objects, as one
  `MultiMesh` draw. Stars are white points, all the same size; brightness follows
  their real magnitudes with one uniform boost. Planets are small coloured discs.
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

`PlayerCamera` has two modes, toggled with F5. Third person orbits the target,
optionally swings back behind a vehicle's heading when the player stops looking
around, and never dips below the water surface. First person sits at the
player's head (the model is hidden so you don't see out through it) and looks
along the same yaw and pitch; it follows the head down if you sink.

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
- **Lighting.** Three-band toon shading of each puff as a sphere, darker toward
  the cloud base. The sunlight colour is computed per frame for the cloud
  layer's height, which still sees the sun a little after sunset at sea level.
  That light is kept fully saturated (stylised), so clouds glow orange and pink
  through the afterglow, then go slate-grey.

## Entities

- **Player** (`CharacterBody3D`). Custom swim physics with one buoyancy probe at
  the chest, slightly denser than water. Treading and swimming are force-limited
  kicks toward the surface. Boards boats by distance.
- **Boat** (`RigidBody3D` + `Buoyancy`). Thrust, keel drag (easy forward, hard
  sideways), a rudder that bites with speed, bow lift, lean into turns.
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
- **A new level:** a scene under `src/world/<name>/` that instances `Ocean` (if
  it has sea), a `WorldEnvironment`, a sun, and the entities it needs.
- **A minigame:** see `src/minigames/README.md`.
