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

- **Start menu** (`src/ui/main_menu/`, the main scene): Start game (not made
  yet) or Debug mode, which opens the open-ocean sandbox.
- **HUD** (`src/ui/hud/`): the status readout (with fall speed), contextual
  controls, flash messages and the breath gauge, a circle filled from the
  bottom up with the breath you have left.
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
| `water.gdshader` | Displaces the mesh, computes per-pixel normals (analytic Gerstner + ripples + procedural small waves, see below), refraction and depth absorption from the screen/depth textures and crest scattering. No foam. Sky reflection and sun glints come from Godot's own lighting. |
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

### Terrain (`src/systems/terrain/`)

**The world is generated offline.** `tools/gen_world.py` makes a 20 x 20 km
test world of islands from a seed and writes it to `world/` (see
`world/README.md`): 16-bit heights at 2.5 m with their mips, ground masks,
rivers, stand-in trees and the start. Everything that makes terrain look
real (erosion at 10 m, 5 m and 2.5 m, rivers carved together with their
water level) happens there, where there's time for it, so the game only
loads and draws (about a second for the 8192 x 8192 heights). The world is
small and the mountains are game-scale (peaks around 800 m); detail at every scale, haze, ambient occlusion and the trees are
what make it read as big. Far land turns blue (the terrain shader shifts
its colour with distance) under a blue haze: the environment's fog, half its
own colour (set by `Atmosphere` with the time of day: blue by day,
blue-violet at dusk, dark at night) and half the sky's toward the horizon,
and kept off the sky, so sunsets and stars keep theirs.
Under a river standing above the sea the bed is its sand, blending into the
seabed's as the river comes down to the sea.

- **`WorldData`** loads it once: the two height byte planes (high and low)
  stay as bytes for CPU queries (`height_at`, bilinear; `surface_at`, exactly
  the triangles the terrain draws) and become two mipmapped R8 textures for
  the shaders, with no per-pixel work at load.
- **Drawing** (`terrain.gd`, `terrain.gdshader`): a CDLOD quadtree of
  16 x 16 patches (`MultiMesh`). A patch of LOD k has vertices 2.5 m * 2^k
  apart, exactly on mip k's samples, and morphs toward k + 1 at the edge of
  its range; ranges are four patch widths per LOD, which keeps seams closed.
  The shader decodes heights texel by texel and filters them itself, takes
  per-pixel normals from the finest mip the pixel can show, and colours the
  ground naturally (grass greener or drier in patches and with height,
  darker forest floor, rock on steep ground, sand), darkened by the baked
  ambient occlusion. Far land sinks by d^2 / 2R with the planet's curve.
- **Physics**: a `HeightMapShape3D` at the samples' own 2.5 m spacing (400 m
  across) follows the player and is rebuilt when they have moved 100 m;
  `prepare_at()` builds it before someone is put somewhere.
- **Trees** (`TreeScatter`): dark green pyramids, 7-25 m, from
  `WorldData.trees`, in 512 m chunks (one multimesh each) that fade out by
  3.2 km; the darker forest floor carries the forests beyond.
- **Rivers** (`src/systems/water/river/`): `RiverWater` draws each river as a
  ribbon mesh along its centreline (`RiverRibbons`, `river.gdshader`): level
  across, reaching just past the banks, where the ground cuts its edge. The
  water is substantial: its body colour is always there (only a little of
  the bed shows through), so it never thins away in the shallows or with
  the viewing angle. The surface is after P_Malin's "Adrift" (without its
  foam): a fractal of value noise with analytic derivatives, each octave
  carried by the current and the next the other way at 3/4 speed, each
  warped up its own gradient, which gives the boils and slicks of real river
  water. It is laid out in world space and carried along the current by two
  crossfaded phases, so it follows every bend without stretching; it runs
  fastest mid-channel and flattens where the water is fast, and it and the
  gloss fade out where they would be finer than a pixel; each octave is
  turned from the last, so no grid shows. Light through the water dies away
  red and green last. The bed (sand and gravel) shows through, fading with
  the water over it, but never more than about 80% of it (clear water:
  whatever lies on the bed shows well), so the water never vanishes at its
  edges. Below each riser the current is slack and picks up again over a few
  widths (`WorldData._current`, which also doesn't count the drops
  themselves). The water's thickness comes from the depth texture,
  or, where there is none (with MSAA on there isn't), from the channel's own
  depth profile and the viewing angle.
  Falls: steep water comes down in steps the generator cuts into the rock
  (cascades of a few tall risers, and step-pool streams; see
  `world/README.md`), sampled finely. On a pool the water lies level; down
  a riser it lies on the rock as a film: each vertex 0.45 m above the
  ground exactly as the terrain draws it (`WorldData.surface_at`), then
  neighbours lifted wherever the rock between them (across, down, and along
  each triangle's diagonal) would come through, and every vertex held
  between its riser's lip and the pool it falls into, and toward the banks
  no higher than the water's level there (the banks stand higher, so it
  can't spill over them). Round each riser the cross-sections are about a
  metre apart each way; just below one the level water is lifted over any
  rock at its foot (the 2.5 m grid can't make the foot of a tall riser
  sharp), and the junctions between fine and coarse cross-sections lie on
  level water, edge to edge. Down a riser the water is glassy for a moment
  over the lip (the line where it breaks white wavers across it), then
  white and streaming, streaked lighter and darker, its streaks fixed in the
  falling water so they stretch as it speeds up, in strands with narrow gaps
  where the wet rock shows dimly through, whiter where it tumbles over
  little ledges in the face. Below each riser it churns white at the foot
  and the foam drifts away downstream, thinning out (its patterns carried
  out from the foot by two crossfaded phases, so they never shear). Above a
  lip the water runs rough and streaked with white. `RiverSpray` adds the
  splash and mist at every riser's foot: one multimesh of camera-facing
  quads animated entirely on the GPU (`river_spray.gdshader`): clumps of
  spray thrown up and falling back under gravity, higher below a taller
  riser, and soft puffs of mist rising and drifting downstream, lit as a
  translucent white, soft where they meet the ground and gone below the
  water. Round an island the current parts along its shore and closes behind
  it, with a little foam at its head and along its shore. Wakes and
  ripples come from the ocean's ripple simulation (the player swimming, the
  boat), which the river shader reads as well; in a river the simulation
  drifts with its current (each wavelength shifted downstream exactly, in
  the frequency domain), so wakes trail away downstream; steep ones churn
  white. The sun's highlight is the shader's own (a capped GGX `light()`),
  capped lower far off and on white water, and the sky the water reflects
  has the halo round the sun capped (the sky shader's cubemap pass), so no
  reach turns into a glinting blob, near or far. The water's very edge fades
  in over its first 30 cm, so the shore is soft; water that would hang out
  over ground falling away isn't drawn; level water seen from below shows
  its own body, not the sky through it. Falling water is broken water,
  never a mirror; and level water grows rougher with distance as its ripples
  become too fine to show, so the sun on far water is a soft sheen. Seen
  from behind or from below, the surface turns to face the eye rather than
  going black. Where a river comes down to the sea (the trunk's
  estuary, its last 1.5 km at nearly sea level) its water turns into the
  sea's (the same colours and absorption), then it fades out into it as the
  ocean fades in (`WorldData.river_mask()`: the sea isn't drawn under river
  water above sea level, where a riverbed lies below it; the river is drawn
  over the sea; the terrain under it gets no sea-level damp line). On the
  inside of a bend the ribbon reaches no further than most of the way to the
  bend's centre, so a wide reach never overlaps itself. Cross-sections are 2 m apart (round
  risers, much closer), and the surface's frame follows the flow in 3D: down
  a riser the water faces downstream and its streaks run down it. Coming into
  its river, a tributary's water reaches further out over its banks. The ribbons are drawn smallest
  stream first and trunk last, so where a tributary's mouth lies under its
  river only the river shows, with its one current (a tributary curves into
  its river's direction in the generator).
  `RiverBody` is the water body: level and current from the nearest reaches
  (a tile index of segments), so swimmers and boats are carried downstream.
- **The ocean** is the sea wherever the ground is below sea level; its waves
  shoal out in shallow water (shader and physics alike), reading the same
  height map.

### Atmosphere (`src/systems/atmosphere/`)

A single-scattering sky after Sebastian Lague's
[Solar System](https://github.com/SebLague/Solar-System) atmosphere, reworked from
his whole-planet post-process into a Godot sky shader for a camera on the surface.
Because it is the sky, it automatically drives water reflections, ambient light
and distance haze (the environment's fog uses `aerial_perspective = 0.5`: half
the sky colour in that direction, half the fog's own colour, which `atmosphere.gd`
sets with the time of day; what glossy things reflect has the sun's halo capped).

| File | Role |
|---|---|
| `atmosphere_sky.gdshader` | Marches the view ray (16 samples bunched near the camera, dithered). At each sample it looks up the sunlight's optical depth in a baked table and accumulates the view ray's own. Draws the sun disc, reddened by the air in front of it. Below the horizon (the sea covers it) it looks along the horizon instead, and that horizon dips with the camera's height as the planet curves away, so from altitude the sun sets at the true horizon. |
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
  the rose-violet band above the sunset point while the sun is 1-6 degrees down
  (fading in from just before it sets). The sunlight itself is taken halfway
  way toward white and is as bright as the light overall (not its reddest
  part), so a low sun gilds the land rather than washing it red.
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

**Walking** is Minecraft-like: quick to start and stop on the ground,
little air control so momentum carries a jump, Ctrl runs, Shift sneaks,
holding Space hops whenever the feet touch down. Gravity is a real 9.8 m/s^2
going up and 2.2 times that coming down, so a jump rises as before but a fall
off a cliff drops like one, not a float. For a second after pulling up over
an edge you walk slowly, so you don't step straight off it.
Double-tapping Space toggles a fast debug flight; stopping it drops you from
rest, so you fall straight down, accelerating.

**Climbing**: E grabs ground too steep to walk on (normal.y below 0.72,
about 44 degrees) if there is some just in front of you. On the rock there
is no gravity; WASD moves up, down and across it (relative to the rock), Ctrl
faster, the chest held 0.45 m off it and the body turning with it. Where the
rock ends or turns walkable you pull yourself up over the top onto the
ground there (or fall, if there's nothing up there); E lets go. While you
climb the capsule lies along the rock, and it stands upright again only once
the body is clear of the rock, so it can't be pushed through the ground (and
if anything ever does push the body under the ground it's put back on top).
The view switches to third person while you climb, and back to the view you
had once you're off the rock.

**The body** (`CharacterRig`, `src/entities/player/character_rig.gd`) is a
stylized explorer built from primitives (hat, hair, knapsack and bedroll,
sleeved arms, trousers, boots; `CharacterTraits.apply_to()` recolours the
parts tagged skin, hair, shirt and shorts) and animated entirely
procedurally, with two-bone solvers for arms and legs. Walking plants each
foot on whatever is below (a ray down) and steps it in an arc when the body
has moved on; faster than feet can be planted it becomes a running cycle
around the hips, still on the ground below; the arms swing against the legs.
Swimming is a front crawl with a flutter kick, treading sculls, a sinking
body's limbs drift. Climbing holds hands and feet on points of the rock
(rays onto the collider) and moves them in a diagonal gait, left hand with
right foot, each pair reaching on when it has fallen behind. No animation
clips.

`PlayerCamera` has two modes, toggled with F5; the game starts in first person.
Third person orbits the target and never dips below the water surface; it
comes in in front of the ground (a ray from the target to where it would be),
so it never looks through a hill or the slope behind you. The view
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
