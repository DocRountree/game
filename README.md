# game

An exploration-based video game featuring a playable character, a navigable ocean
and rivers, plants, fungi, animals, and land. Built in **Godot 4.7** (GDScript,
with C++ via GDExtension where profiling calls for it).

The sky is a single-scattering atmosphere over the real winter night sky:
naked-eye stars, planets and Messier objects, every day the winter solstice.
A moon goes through its phases day by day. Days last 15 real minutes, nights 10.
The first system in place is the water: a Gerstner-wave ocean that physics and
rendering agree on exactly, spring buoyancy for anything that floats, and an
interactive GPU ripple simulation that turns hulls and swimmers into wakes that
lift and shove whatever they reach.

The land is a generated 20 x 20 km test world (`world/`, made by
`tools/gen_world.py` from a seed): a main island about 8 km across with a
mountain range and a river system (waterfalls on the mountain streams, a trunk
about 130 m wide at the mouth), a peripheral island, an archipelago of about
150 low islands on a shallow bank, a chain of volcanic cones and a southern
group, eroded and carved at 2.5 m, with dark green pyramids standing in for
the trees. You start on a beach
near the river mouth with your boat moored offshore.

Starting the project opens a menu: **Debug mode** enters the sandbox world (Start game is not made yet).

## Running

1. Install [Godot 4.7](https://godotengine.org/download) (standard build; .NET not needed).
2. Open `project.godot` in the editor and press **F5**, or from a terminal:
   ```sh
   godot --path .
   ```

**Renderer:** Forward+ (default) or Mobile. Interactive ripples run as a compute
shader and need one of those; under the Compatibility renderer the ocean, buoyancy
and gameplay still work, just without ripples.

## Controls

| | |
|---|---|
| Mouse | look around (Esc releases the cursor; arrow keys also orbit) |
| Left Shift | sneak when walking; swim down; get off the boat |
| F3 | performance overlay (fps, CPU, GPU, memory) |
| F5 | toggle first-person (default) / third-person view |
| F6 | debug: aurora every night (toggle) |
| M | debug: meteor shower every night (toggle) |
| W A S D | walk (on deck); swim, relative to the camera (look down while swimming to dive) |
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
  systems/          reusable pieces: terrain (the generated world), water (ocean,
                    rivers), time, atmosphere, buoyancy,
                    camera, inventory, exploration, performance
  entities/         things in the world: player, boat, props
  world/            levels / playable spaces (open_ocean is the debug sandbox)
  ui/               HUD and menus
  minigames/        self-contained minigames, one folder each
assets/             imported art and audio (models, textures, audio, fonts)
addons/             third-party editor plugins
native/             C++ GDExtension sources (not scanned by Godot)
world/              the generated world's data (heights, masks, rivers, trees; not scanned by Godot)
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
