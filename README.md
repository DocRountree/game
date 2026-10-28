# game

An exploration-based video game featuring a playable character, a navigable ocean
and rivers, plants, fungi, animals, and land. Built in **Godot 4.7** (GDScript,
with C++ via GDExtension where profiling calls for it).

The sky is a single-scattering atmosphere over the real winter night sky:
naked-eye stars, planets and Messier objects, every day the winter solstice.
A moon goes through its phases day by day. Days last 15 real minutes, nights 10.

The world is hand-painted (`world/`, see `world/README.md`): a 30 km sea with
a main island (a desert mesa, a mountain range and a river system), a
peripheral island, a long archipelago, a volcanic chain and a southern
archipelago. Edit the maps in Krita or GIMP. The game adds the fine detail:
erosion gullies, mesa cliffs, river valleys, dunes and reefs. The first start
after a change bakes the world (about 30 s, behind a loading screen) and caches it.
You start on the shore of the bay by the river mouth, with your boat moored offshore.

The water: a Gerstner-wave ocean that physics and rendering agree on exactly,
waves that shoal and break at the shore, calm lakes, flowing rivers whose
current carries you, spring buoyancy for anything that floats, and an
interactive GPU ripple simulation that turns hulls and swimmers into wakes that
lift and shove whatever they reach.

## Running

1. Install [Godot 4.7](https://godotengine.org/download) (standard build; .NET not needed).
2. Open `project.godot` in the editor and press **F5**, or from a terminal:
   ```sh
   godot --path .
   ```

**Renderer:** Forward+ (default) or Mobile. Interactive ripples run as a compute
shader and need one of those; under the Compatibility renderer the ocean, buoyancy
and gameplay still work, just without ripples.

Starting the project opens a menu: **Debug mode** enters the sandbox world (Start game is not made yet).

## Controls

| | |
|---|---|
| Mouse | look around (Esc releases the cursor; arrow keys also orbit) |
| Left Shift | sneak on land; swim down; get off the boat |
| F3 | performance overlay (fps, CPU, GPU, memory) |
| F4 | world map (debug: the whole baked world, with you on it) |
| F5 | toggle first-person (default) / third-person view |
| F6 | debug: aurora every night (toggle) |
| M | debug: meteor shower every night (toggle) |
| W A S D | walk on land; swim, relative to the camera (look down while swimming to dive) |
| Left Ctrl | sprint (hold with W) |
| Space | jump (hold to keep hopping); swim up / tread water (do nothing and you sink) |
| Space Space | debug: fly (Space up, Shift down, Ctrl faster; double-tap again or land to stop) |
| Right mouse | board the boat |
| W / S, A / D | on the boat: throttle / reverse, steer |
| [ / ] | scrub time of day backward / forward |
| R | respawn beside the boat |
| Esc | release the mouse (quit by closing the window) |

## Layout

```
project.godot       engine settings, input map, physics layers
src/                all game code and scenes, grouped by feature
  autoload/         global services: Events (signal bus), Game, Settings, Perf
  core/             world-wide basics: WorldConfig (seed, latitude, date), WorldGrid
  data/             Resource schemas and instances: items, species, biomes, boats, characters
  systems/          reusable pieces: terrain (world generation), water (ocean,
                    lakes, rivers), time, atmosphere, buoyancy,
                    camera, inventory, exploration, performance
  entities/         things in the world: player, boat, props
  world/            levels / playable spaces (open_ocean is the main scene)
  ui/               HUD and menus
  minigames/        self-contained minigames, one folder each
assets/             imported art and audio (models, textures, audio, fonts)
addons/             third-party editor plugins
native/             C++ GDExtension sources (not scanned by Godot)
tests/              headless tests
tools/              build, export and test scripts (not scanned by Godot)
docs/               architecture, conventions and the roadmap of planned systems (not scanned by Godot)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the systems fit together
and [docs/CONVENTIONS.md](docs/CONVENTIONS.md) for naming and structure rules.

## Tests

```sh
tools/run_tests.sh            # uses `godot` on PATH, or set GODOT=/path/to/godot
```

Runs the main scene headless and checks the core water gameplay: things float,
an idle swimmer sinks, treading recovers, the boat can be boarded and driven.
