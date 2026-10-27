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
| `water.gdshader` | Displaces the mesh, computes per-pixel normals (analytic Gerstner + ripples + procedural small waves, see below), refraction and depth absorption from the screen/depth textures, crest scattering. Sky reflection and sun glints come from Godot's own lighting. |
| `ripple_sim.gd` / `ripple_sim.glsl` | Interactive ripples on the GPU (see below). |
| `ocean_fft.gd` / `ocean_fft.glsl` | The small waves: an FFT ocean spectrum on the GPU (see below). |

**Height queries.** `surface_height(x, z, footprint, ripple_radius)` returns the swell
height above a world point. Gerstner moves water sideways, so it first finds the
undisplaced point that lands on `(x, z)` (three fixed-point iterations).
`footprint` low-passes the swell so a large hull ignores short waves.
`ripple_radius >= 0` adds the interactive ripples.

**Small waves (FFT ocean).** `ocean_fft.gd` / `ocean_fft.glsl`, after
Tessendorf's "Simulating Ocean Water". A Phillips wind-wave spectrum (broad
directional spreading, gravity-capillary dispersion) is evolved in time and
inverse-FFT'd on the GPU into surface slopes every frame, in three 256x256
cascades with tile sizes 97 m, 13.7 m and 2.31 m. Each cascade owns a band of
wavelengths (20-3 m, 3-0.3 m, 0.3 m down to ~2 cm), so nothing is counted twice,
and the odd size ratios keep their repeats from lining up. One compute shader,
12 small dispatches a frame: evolve the spectrum, a row and a column FFT in
shared memory (one workgroup per line), write the slopes, then a mip chain so
distant water averages instead of sparkling. The water shader samples the three
textures at the undisplaced position, so the detail rides the swell. Physics
ignores it (the Gerstner swell does the floating); without a RenderingDevice
the detail is flat.

**Wakes and ripples.** A 256 x 256 grid (0.4 m cells, ~102 m) that scrolls
with the player holds the water's height and vertical velocity. Each physics frame:

1. Every node in the `ripple_sources` group reports a footprint (hull, box or
   disc) and how deep it sits in the swell. The compute shader turns *changes*
   in that occupancy into displaced water (height only, no kick): a moving
   hull pushes water out at the bow and lets it back in at the stern.

2. Height and velocity are packed into one complex field and FFT'd (the same
   shared-memory FFT as the ocean). Every wavelength is advanced *exactly* by
   its own deep-water frequency, omega = sqrt(g k + sigma k^3), then
   transformed back. Long waves outrun short ones, so a moving hull leaves a
   proper Kelvin wake (the 19.5 degree V, with feathered diverging waves and
   transverse waves behind) and a swimmer makes dispersing rings. Exact in
   time, so one step per frame is stable at any speed; short ripples are
   damped a little faster than long waves.
3. A sponge border soaks up outgoing waves, so the FFT's wrap-around never
   brings them back.
4. The result goes to the water shader as a `Texture2DRD` (stays on the GPU) and
   back to the CPU with `texture_get_data_async` for physics, about a frame late,
   with no stall.

(This replaced a plain wave equation, whose single wave speed gave a smeared
V and rings. A short convolution kernel (Tessendorf's iWave) was tried first,
but a 13 x 13 kernel can't get deep-water speeds right across these wavelengths.)

Objects read ripples on a ring just outside their own footprint, and compute
their displacement against the swell only. That breaks the feedback loop where
an object would sink into its own displacement trough.

### Terrain and world generation (`src/systems/terrain/`)

**The bake** (`world_gen/world_bake.gd`, CPU, deterministic) runs once per
`(seed, WorldBake.VERSION, resolution)` and is cached as a `WorldMaps` file in
`user://worlds/`. `Terrain` runs it on a worker thread at start (about 12 s for
the default 1600 x 1600 grid of 51 m cells, an 82 km world), and the HUD shows
progress; until it finishes the world is open ocean.

1. `WorldLayout` lays the land out around a main continent (mountain belts
   along random curves): an archipelago scattered off one coast and a volcanic
   chain trailing away from another, a big young volcano with a crater first,
   then smaller, older islands with open water between them. The spawn point is
   picked offshore, away from both, and the whole world is shifted so it is the
   origin (`WorldMaps.center` is the grid centre in world coordinates).
2. Each gives a land shape (warped, noisy coastline) and an uplift rate.
3. Mountains and valleys are the steady state of stream-power erosion: a
   channel's slope is `U / (K sqrt(A))` (A = drained area), so heights follow
   from the drainage tree in one pass upstream from the coast. Six rounds of
   re-routing water down the new slopes give dendritic valleys and sharp ridges.
   Heights are scaled per landmass to its target peak (continent 0.7-1.3 km),
   slopes capped at 30 deg so mountains can be climbed.
4. Seafloor: shelf, slope and deep sea by distance from the coast.
5. Lakes are placed on river valleys: a basin is scooped around an outlet and
   flooded to a level held by a rock sill, so every lake is fed by its river
   (wet or dry). Some (more in dry places) have no outlet.
6. Climate: temperature from height; rain from moist sea wind rising over the
   land (rain shadows behind mountains).
7. Water today: runoff accumulates downstream, channels lose water in dry
   country, so beds carved in a wetter past can run dry; lakes fill to their
   sill or shrink until evaporation matches inflow (or dry out).
8. Rivers: every channel draining more than about 0.3 km^2 is traced, so
   rivers have many tributaries. Each path is resampled every 24 m and
   smoothed; width and depth come from today's flow (past flow for dry beds).
   Big rivers lay down alluvial plains: every cell within ~28 widths of a
   river takes its floor from the nearest river point of any river (just
   above that water, curving up to the valley sides), never below a nearby
   lake. No river then runs above the ground beneath it (its water is clamped
   to the ground, only ever lowered, and steps eased into ramps). The
   centreline then meanders as a sine-generated (Kinoshita) curve traced in
   12 m steps: direction swings by omega sin(phase) plus a skewing third
   harmonic, wavelength ~13 widths, with wavelength and swing wandering so no
   two bends match; omega (up to 1.4 rad: horseshoes) is limited by how much
   flat floor there is on both sides, and the curve is steered back toward
   the valley line so it never drifts. Beside big loops sit copies of loops
   the river used to have, moved out and downstream onto open floor clear of
   today's channel: shallow dry meander scars (sometimes several, like scroll
   bars), the outermost sometimes still water, an oxbow lake. Water thins in
   from a trickle where a river starts to flow and out where it dries up, and
   channels narrow toward their heads. `RiverNetwork` turns all of it into straight
   segments with a 256 m tile index, for the GPU and for physics alike.
9. Ground: sand on archipelagos, beaches and the seafloor, rock on volcanoes,
   dirt on continents, lake beds.

**Drawing.** `terrain_levels.glsl` keeps 11 nested 256 x 256 height levels
(0.5 m to 512 m spacing) centred on the camera: the baked height (cubic
B-spline, read from a 2x2-averaged mip of the grid matching the level's
spacing, so coarse levels never alias the grid and far mountains hold still),
plus band-limited, derivative-damped fractal detail (a few metres) and the
river channels carved from the exact distance to the river segments (found
through the tile index): a rounded bed, banks rounding onto a floodplain just
above the water, rising gently (no walls) and blending smoothly back into the
ground ten half widths out, the lowest of all nearby channels so confluences
merge. Widths grow with flow; below a confluence the river eases out to wider
than either tributary (the root of their squared widths) and never narrows
downstream. The bed still slopes where it meets the water
and the banks carry that slope on up before rounding over: a bed meeting the
water flat would turn tiny mesh errors into a sawtooth shoreline. Detail is
calm for several widths around rivers, levees rise gradually from the
waterline, and the terrain mesh alternates its quad diagonals. `terrain.gdshader` draws a CDLOD quadtree of 16 x 16
patches (`MultiMesh`): a patch of LOD k reads level k, morphing toward k + 1 at
the edge of its range. Ranges are four patch widths per LOD, so the farthest
patch of LOD k - 1 ends before LOD k starts morphing, which keeps seams closed.
Far terrain and water sink by d^2 / 2R (the planet's curve), so from a height
the sea meets the sky at the true horizon. The morph uses the main camera's
position (a uniform), also in the shadow pass, so shadows hold still.

The sky's moon, stars, planets, meteors and aurora are pushed to the far plane
in their vertex shaders, so terrain always draws in front of them.

**Physics and queries.** Level 1 (1 m spacing, 256 m) is read back into a
`HeightMapShape3D` that follows the player when they have moved 48 m. Without a
GPU it is built from the baked map. `Terrain.height_at(x, z)` uses it near the
player, the baked map elsewhere. `Ocean.contains_point` is "ground below sea
level"; lakes (`LakeBody`) and rivers (`RiverBody`) are water bodies built from
the bake, so buoyancy, swimming, currents and sampling work in them unchanged.

**Water on land.** The ocean shader shrinks each Gerstner wave where the water
is shallower than a third of its length (physics
matches). Lakes reuse the ocean shader without swell, masked to their basin.
Rivers, oxbow lakes and lakes are one water sheet drawn on the terrain's own
patches with `river.gdshader`: the compute pass writes a second level array
(sheet height, current) from the same segments that carve the
channels and the baked lake levels. The sheet runs level a little past the
water's edge, then dives under the ground, so shorelines are wherever the
ground meets the water; where a river meets a lake the higher surface wins
(continuous, since the river ends at lake level), and at the sea the river
water slips just under the ocean's surface. Per pixel, the water fades out by
its true depth (water level minus the filtered terrain height), so shorelines
are soft curves. The look is the ocean's (colours, refraction, absorption), but the small
waves are a still ripple field (gradient noise) that only the current moves,
so the water always visibly runs downstream (the ocean's own FFT waves travel
by themselves and read as water running uphill): two phases, crossfaded,
choppier in fast water;
lakes are the same water with no current. There is no foam anywhere. Currents push swimmers
and boats.

**Moving on land** is Minecraft-like: quick to start and stop on the ground,
little air control so momentum carries a jump, Ctrl runs, Shift sneaks,
holding Space hops whenever the feet touch down. Double-tapping Space toggles
a fast debug flight. `ProceduralLegs` plants each foot on the collider (a ray down)
and steps it in an arc when the body has moved on, alternating feet, with a
two-bone solver bending the knees. No animation clips.

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
  `night_minutes` (10). Time eases from day speed to night speed through
  twilight, so the sunset glow lasts about a minute instead of rushing by. The
  night speed is solved numerically so the night still comes to exactly 5 minutes.
- **Moon** (`moon.gd`, `moon.gdshader`, `Planets.moon_direction`).
  Low-precision lunar theory: mean elongation, anomaly and argument of
  latitude, plus the three largest periodic terms, placed relative to the fixed
  sun. Its clock runs fast: a lunation takes `WorldConfig.lunar_cycle_days`
  (8) game days instead of 29.5, so each of the eight named phases lasts one
  day. The phase name comes from the mean elongation at noon, so it changes
  exactly at midnight and never repeats or skips a day; the drawn shape and
  position come from the full theory. It rises about 3 hours later each day and
  is up by day for half the cycle. It is drawn as a sphere lit by the actual sun
  direction (5x real size, so the phase is visible). By day it adds to the sky;
  at night it covers the stars. A `Moonlight` directional light scales with
  phase and altitude, so a bright moon lays a glitter path on the sea.
- **Meteors** (`meteors.gd`, `meteors.gdshader`): white streaks that taper from
  a thread to a round, bright head, racing 15-45 degrees across the sky in under
  a second. Random arrivals (about one every 25 s of night), only at night,
  drawn in front of the stars. `launched` counts them.
- **Aurora** (`aurora.gd`, `aurora.gdshader`): a 3D emission field above a
  round Earth, drawn on a sky dome. Each night independently has a 1-in-50
  chance (`chance`) from the world seed; a night belongs to the day it began.
  - *Pillars first.* 1-3 curtains, each made of field-aligned pillars at two
    scales with gaps, each pillar with its own base height and length (ragged,
    staggered, soft bottoms) and brightest near its bottom. A curtain only
    reads as a sheet where pillars crowd together.
  - *Folding without crossing.* Curtains are straight lines (plus gentle folds,
    slope under 0.6) in an unwarped plane, stacked north to south with at least
    15 km between their fold envelopes. Swirls then warp the plane: each
    rotates points about a centre by an angle that fades with distance, so it
    maps every circle to itself and is an exact bijection. The curtains become
    S folds, spirals and folds within folds (some swirls nest a smaller one)
    but can never cross themselves or each other; the shader undoes the
    swirls exactly to evaluate them. Both properties are tested.
  - Field lines tilt toward the equator as they rise, so overhead pillars
    converge on the magnetic zenith.
  - Per pixel, the view ray is stepped through 30-450 km of altitude (low enough that soft bottoms are never cut off); near or
    inside a sheet each step is refined into exact sub-steps, and per sub-step
    the length of ray inside the sheet's profile is integrated in closed form,
    with the light blended from both ends. Edge-on sheets glow and pixels change
    smoothly: no stripes, grain or moire (an earlier per-pixel jitter caused
    stippling, and plain steps caused moire where rays graze swirled sheets).
    The light for each sub-step is taken where the ray comes closest to the
    sheet. Pillar detail fades by a distance-based estimate of pixel size:
    deriving it from the folded along-curtain coordinate (fwidth or finite
    differences) made the fade jump where swirls bend that coordinate, drawing
    dark dashes across distant curtains. The structureless glows are sampled
    only within their own thin layers for the same reason.
  - Near the horizon the light fades through the thick, hazy low air, so
    curtains melt into the horizon instead of being clipped by the sea. Bottoms
    are soft (10-35 km), and where pillars are too fine to show, their
    raggedness widens the fade rather than vanishing.
  - Colour by altitude, per curtain and drifting along it: green from
    yellow-green to cyan, red or blue-violet tops, sometimes magenta lower parts.
    Only genuinely bright light whitens.
  - Storm strength places the oval (strong nights overhead or south); the oval
    drifts, curtains swell and fade on their own, swirls sway and wind and
    unwind. Optional faint high red glow and soft pulsing green patches.
  - `time_scale` speeds up, slows or freezes the display for tuning. Shader
    knobs on the material: `gain` (brightness), `saturation` (below 1 pulls
    toward grey, so stars show through), `blur` (softens pillars, sheet edges
    and bottoms; distant pillars merge into a glow).

- **One rotation for everything.** `Astronomy.equatorial_to_world()` turns
  equatorial coordinates (right ascension, declination) into the local sky from
  local sidereal time and latitude. The sun, stars, planets and deep-sky
  objects all go through it. World axes: +X east, +Y up, -Z north.
- **Planets** (`planet_layer.gd`, `planet_layer.gdshader`): small coloured
  discs on their own layer at 2,450 m, in front of the stars, behind the moon
  (which can pass over them). They wander from day to day.
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
segments, and detail and far distances for future LOD and
culling. `Perf` keeps smoothed frame time and render counts.

## Data (`src/data/`)

| Schema | Holds |
|---|---|
| `ItemDef` / `ItemStack` | Anything carried: tags (`tool`, `rod`, `net`, `trap`, `sample_container`, `optic`, `wearable`, `catch`) and free-form stats (`magnification`, `breath_seconds`, ...). |
| `SpeciesDef` | An organism: kind (fish, invertebrate, plant, microbe), catch methods (rod, net, trap, sample), habitat (waters, depth, salinity, temperature, active hours), size, schooling, rarity. |
| `BiomeDef` | A habitat (`open_ocean.tres` so far): medium, depth range, map colour, species list, `species_for(depth, hour, water)`. |
| `BoatSpec` | Handling, speed and cargo: mass, size, thrusts, steering, drags, bow lift, lean, hold slots and weight. `small_motorboat.tres` reproduces the original boat. |
| `CharacterTraits` | Height, build, skin, hair and clothing colours, free-form features. `generate(rng)` for NPCs; `apply_to(model)` dresses the capsule model. |
