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

### Astronomy and the night sky

Every day is the same day: the 2026 winter solstice at 35 degrees north. The
clock alone drives the sky, so it repeats exactly each day.

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

### Camera (`src/systems/camera/third_person_camera.gd`)

Orbiting third-person camera. Optionally swings back behind a vehicle's heading
when the player stops looking around. Never dips below the water surface.

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
