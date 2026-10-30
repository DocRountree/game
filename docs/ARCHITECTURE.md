# Architecture

## Principles

- **One source of truth per phenomenon.** The ocean's waves live in one place
  (`Ocean.waves`) and are evaluated identically by physics (GDScript) and
  rendering (shader). Anything that floats reads the same surface it is drawn on.
  Time lives in `GameClock`, sky positions in `Astronomy`, world facts in `WorldConfig`.
- **Ask a query API, not a node.** Gameplay asks `Water.surface_height(x, z)`,
  `Terrain.height_at(x, z)`, `GameClock.current()`, `WorldConfig.current()`
  instead of holding references to a particular ocean, terrain or level. New
  kinds of water, terrain or worlds slot in behind the same questions (a
  `WaterBody`, a `TerrainSource`).
- **Data in Resources, behaviour in systems.** Items, species, biomes, boats and
  character looks and accessories are `Resource` definitions in `src/data/`,
  found by `ContentRegistry`. A new boat, fish or hat is a new `.tres`, not new
  code.
- **Each thing keeps its own rules.** The camera reacts to what happens to the
  player (Events), the player's movement modes decide their own hand-overs,
  the HUD reads what it shows; the level only puts things together.
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
- **The level** (`src/world/open_ocean/`) only puts things together: the
  `WorldLoader` (below), ocean, sky, player, boat, camera, HUD,
  `UnderwaterView` (the murk with the camera under the surface),
  `ShaderGlobals` and `DebugTools`; it places the player and the boat, and
  respawns the player beside the boat (R, or on drowning).
- **`WorldLoader`** (`src/world/world_loader.gd`) builds the generated world
  in a fixed order: loads `WorldData`, puts its ground in use for every ground
  question (`Terrain.use(HeightmapSource)`) before any child is ready, lets
  its `Terrain` child build the land, then adds the rivers (`RiverWater`) and a
  **`ChunkStreamer`** (`src/world/streaming/`), which streams every
  registered `ChunkSpawner`'s content in 512 m chunks round the camera
  (nearest first, a few a frame, freed well out of view): the trees
  (`TreeSpawner`) now, plants, rocks, animals, items and structures later.
- **`ShaderGlobals`** (`src/systems/rendering/`) sets the global shader
  uniforms every world shader shares (`world_globals.gdshaderinc`, declared
  in `project.godot`): `world_time`, `world_view_pos` (the main camera, also
  in shadow passes), `sun_direction`, `sun_color`, `planet_radius`, and
  `planet_drop()` for the planet's curve. A new shader gets them with one
  `#include`.
- **`DebugTools`** (`src/systems/debug/`): the debug world's F3 readout, F6
  aurora, M meteors and C character picker; a real game world leaves it out.
- **Events** currently emitted: `day_changed` (clock), `player_water_changed`,
  `player_submerged_changed`, `player_mode_changed`, `boat_boarded` (player),
  `player_drowned` (player stats), `area_explored` (exploration),
  `view_mode_changed` (camera), `message` (anything with news for the HUD),
  `panel_open_changed` (the character picker).

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

**The world is generated offline.** `tools/worldgen` makes a 20 x 20 km
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

- **Ground questions go through `Terrain`'s static queries**: `height_at`
  (smooth), `surface_at` (exactly the triangles drawn and collided),
  `normal_at`, `ground_at` (the masks). They ask the `TerrainSource` in use
  (`Terrain.use()`); with none there is no ground (`Terrain.NO_GROUND`, and
  water is `floor_depth` deep). `HeightmapSource` answers for the generated
  world; a second world, a streamed one or a test's made-up ground (see
  `tests/river_test.gd`) is another source. `WaterBody.floor_depth_at` asks it.
- **`WorldData`** is only the file loader, in the format `world/schema.json`
  describes (it checks the version and the fields): the two height byte
  planes (kept as bytes, and two mipmapped R8 textures for the shaders), the
  masks, trees, islands, landmasses, the start, and the rivers as
  `RiverData` (points, widths, depths, the precomputed current, how far down
  a fall each point is, its `FallData` falls, which river it joins) with
  their `RiverNetwork` (a tile index of the segments for "which channel is
  here", the falls by height, the mask of where river water stands above the
  sea).
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
- **Trees** (`TreeSpawner`, streamed by the `ChunkStreamer`): dark green
  pyramids, 7-25 m, from `WorldData.trees`, a multimesh per 512 m chunk,
  fading out by 3.2 km; the darker forest floor carries the forests beyond.
- **Rivers** (`src/systems/water/river/`): `RiverWater` draws each river as a
  ribbon mesh along its centreline (`RiverRibbons`, built in stages in
  `ribbon/`: the centreline and its frames, the falls along it, the
  cross-sections, the falls' rock and landings, then the vertex attributes;
  `river.gdshader`): level
  across, reaching just past the banks, where the ground cuts its edge. The
  water is substantial: its body colour is always there (only a little of
  the bed shows through), so it never thins away in the shallows or with
  the viewing angle. Its optics are the sea's: both shaders share
  `water_core.gdshaderinc` (refraction from the screen and depth textures,
  never pulling in what's in front of the water; Beer-Lambert absorption over
  the water crossed; Fresnel), each with its own colours. A river's colours
  depend on its setting: clear, blue-green mountain water high up, silty
  green-brown lowland water down by the sea, deep blue-green in a plunge
  pool (absorption, body and scattered colour blended per pixel by height
  and how close the foot of a fall is). Its small waves are the sea's FFT
  slopes (three cascades, the longest at a third of its size for broader
  swirls), laid out in world space and carried downstream by the current with
  two crossfaded phases, so they follow every bend; rougher where it runs
  fast, over rapids, in a plunge pool and round an island, mipmapped so far
  water averages out. Without a RenderingDevice (no FFT) a flowing value-noise
  fractal after P_Malin's "Adrift" stands in. The level water carries no
  foam. The bed (sand and gravel) shows through, fading with
  the water over it, but never more than about 80% of it (clear water:
  whatever lies on the bed shows well), so the water never vanishes at its
  edges. Below each fall the current is slack and picks up again over a few
  widths (`RiverData.current()`, which also doesn't count the drops
  themselves). The water's thickness comes from the depth texture,
  or, where there is none (with MSAA on there isn't), from the channel's own
  depth profile and the viewing angle.
  Falls: each is one steep drop the generator cuts into the rock (see
  `world/README.md`), sampled finely down its face. Its face is stepped in
  rough, light terracing (`FallFace`: rows of ledges, each row offset from
  the last like rough brickwork, each ledge's top a little higher or lower
  than its neighbours'), and the water comes down it in a few separate
  streams with bare rock between: each leaves the lip at its own place and
  width and falls nearly sheer from ledge to ledge, stepping aside a little,
  swelling or narrowing where it drops off one, now and then splitting in
  two or (a thin one) giving out. `RiverRibbons` builds the face's rock (a
  relief standing out from the ground exactly as the terrain draws it,
  `WorldData.surface_at`, where the streams come down, sinking back under
  the ground out beside them; just above the lip it rises out of the bed
  between the streams and stands above the water, so the river parts round
  it into them; `fall_rock.gdshader` colours it exactly as the terrain
  colours the ground there, sand and all, and shades it mostly by the
  ground's own normal, so it looks the same as the cliff round it and only
  its outline tells the ledges apart; solid, so you climb on the ledges you
  see and the camera keeps out of them) and lays the water over it with
  cross-sections about 0.4 m apart each way; the shader reads the same
  ledges and streams from two small textures, draws each stream (glassy for
  a moment at each ledge, then white and streaming in strands, churning
  white where it lands on the ledge below, its sides ragged) and leaves the
  rock between bare. Just below a fall the level water is lifted over any
  rock at its foot (the 2.5 m grid can't make it sharp), and the junctions
  between fine and coarse cross-sections lie on smooth water, edge to edge.
  Above a lip the water runs level right to the brink, parting round the
  rock between the streams. `RiverSpray` adds the splash and mist: one
  multimesh of camera-facing quads animated entirely on the GPU
  (`river_spray.gdshader`): clumps of spray thrown up and falling back under
  gravity wherever one of a fall's streams lands at its foot (higher below a
  taller fall) and smaller
  ones wherever a stream lands on a ledge, and soft puffs of mist rising and
  drifting downstream, lit as a translucent white, soft where they meet the
  ground and gone below the water. Round an island the current parts along
  its shore and closes behind it. Wakes and ripples come from the ocean's ripple simulation (the player swimming, the
  boat), which the river shader reads as well; in a river the simulation
  drifts with its current (each wavelength shifted downstream exactly, in
  the frequency domain), so wakes trail away downstream. The sun's highlight is the shader's own (a capped GGX `light()`),
  capped lower far off and on falling water, and the sky the water reflects
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
  falls, much closer), and the surface's frame follows the flow in 3D: down
  a fall the water faces downstream and its streaks run down it. Coming into
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

The camera keeps its own rules, from what happens to the player it follows
(Events): F5 toggles first and third person (in first person the player's
body is hidden); taking a boat's helm (`boat_boarded`) follows the boat from
9 m back, turning with it; climbing (`player_mode_changed` to CLIMB or
MANTLE) is seen from behind in third person, and the view goes back to what
it was once you're off the rock.

### Player (`src/entities/player/`)

The player's movement is one **mode** at a time (`PlayerMode`, in
`modes/`): `WalkMode`, `SwimMode`, `ClimbMode`, `MantleMode`, `DriveMode`,
`FlyMode`, each with `enter`, `exit`, `physics(delta)`, `input` and
`orient`. The active mode runs the body and decides itself when to hand over
(`Player.change_mode`): walking into water hands over to swimming and back,
E on steep rock to climbing, the rock's top to mantling and then walking,
right-click near a boat to driving, Shift to jumping off. `Player.state` is
the active mode's id; `pose` is what the body is doing within it (treading,
sinking, airborne ...), set by the mode as it runs, for the rig and the HUD.
The modes act on a `PlayerIntent` (move, rise, jump, sprint, sneak) read
from the controls each frame, or an empty one while `input_locked` (the
character picker); an animal's or NPC's brain can fill one instead.
**`PlayerStats`** holds the body's condition and its records: breath (it runs
out with the head under, over the breath-hold plus held gear's, and the
player drowns) and running totals.

**Walking** is Minecraft-like: quick to start and stop on the ground,
little air control so momentum carries a jump, Ctrl runs, Shift sneaks,
holding Space hops whenever the feet touch down. Gravity is a real 9.8 m/s^2
going up and 2.2 times that coming down, so a jump rises as before but a fall
off a cliff drops like one, not a float. A jump carries at most 15 m/s of
your speed across the ground (a running jump doesn't sail), and the faster
you run the harder you keep to the ground, so running over a crest or down a
slope doesn't throw you into the air. For a second after pulling up over
an edge you walk slowly, so you don't step straight off it.
Double-tapping Space toggles a fast debug flight; stopping it drops you from
rest, so you fall straight down, accelerating.

**Climbing**: E grabs ground too steep to walk on (normal.y below 0.72,
about 44 degrees) if there is some just in front of you. On the rock there
is no gravity; WASD moves up, down and across it (relative to the rock), Ctrl
faster, the chest held 0.45 m off it and the body turning with it. Where the
rock ends or turns walkable you pull yourself up over the top onto the
ground there if you're climbing up and there's room to stand (a little ledge
in the rock, like those down a waterfall, you climb on past), or fall if
there's nothing up there; E lets go. While you
climb the capsule lies along the rock, and it stands upright again only once
the body is clear of the rock, so it can't be pushed through the ground (and
if anything ever does push the body under the ground it's put back on top).
The view switches to third person while you climb, and back to the view you
had once you're off the rock.

**The body** (`CharacterRig`, `src/entities/player/character_rig.gd`) is a
stylized explorer built from primitives (a face with eyes, brows, nose and
mouth; a collared shirt with rolled sleeves, hands with thumbs, knapsack and
bedroll, trousers, boots), drawn as 14 meshes with one material
(`character.gdshader`): every vertex names its colour slot in a palette
uniform, so a recolour is one uniform change. The static body is one mesh,
each limb one, and the part that changes shape with the look is another
(`CharacterDress`, in the head's frame): hair grown by `HairBuilder` (a
scalp cap and clumps of tapered tubes from fixed roots; length runs them on,
falling under gravity, combed back from the face and slid round the head,
neck, shoulders, pack and bedroll; curl turns them to helices, shortens and
fattens them; a ponytail or bun gathers them; a hat presses them down),
facial hair (stubble, moustache, goatee, beard), the hat (wide brim, cap,
beanie, bandana) and accessories (glasses, earrings, necklace, scarf,
headband). The hair trails the head's motion and hangs to gravity (a sway
uniform from a spring on the head) and is darker and flatter after time in
the water. `CharacterTraits.apply_to()` scales the model, sets the palette
and rebuilds the dress. In the debug world C opens the character picker
(`CharacterPicker`): a camera facing the frozen player (drag to turn them)
and a panel of sliders and swatches (skin: 12 skin tones, then simple
colours red to violet); Done (or C, Esc) saves the look to
`user://player_traits.tres`, which the player loads on start. It is all
animated
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
| `CharacterTraits` | Height, build, skin, hair (length, curl, colour), facial hair, hat, accessories and clothing colours; the picker's palettes. `generate(rng)` for NPCs; `apply_to(model)` scales, recolours and dresses a CharacterRig model. |
| `AccessoryDef` / `AccessoryPart` | A hat, an accessory or a hair style (`characters/accessories/*.tres`): its palette slot, default colour and parts (meshes placed on the head, some fitted over the hair). The picker offers whatever is there. |

`ContentRegistry` finds every definition under `src/data/` on first use:
`ContentRegistry.all(&"AccessoryDef")`, `ContentRegistry.by_id(&"ItemDef", &"snorkel")`.
New kinds of content (plants, animals, structures, NPC archetypes) are new
definition classes, found the same way.
