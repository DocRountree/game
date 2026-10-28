# The world's maps

The world is built from these hand-painted maps. Edit them in Krita (or GIMP),
save, and the game re-bakes the world the next time it starts. If the change
doesn't show, delete the cached bake: `~/.local/share/godot/app_userdata/<project>/worlds/`
on Linux, `%APPDATA%\Godot\app_userdata\<project>\worlds\` on Windows. Or bump
`WorldBake.VERSION`.

This folder has a `.gdignore`, so Godot doesn't import these files. The bake
reads the PNGs directly, so 16-bit heights keep their full precision.

## Layout: `layout.json`

- `world_size`: the world is a square this many metres across (300000, i.e. 300 km). The origin is its
  centre, x runs east and z south, so north is -z.
- `sea_value`: in height maps, values at or below this are sea (0.02).
- `spawn`: where the player starts, world x and z. Put it in open water.
- `landmasses`: each one names its maps and places them:
  - `center` (x, z) and `size`: the square of the world the maps cover, in metres.
  - `peak`: the height in metres that pure white means.
  - `kind`: `continent`, `island`, `archipelago` or `volcanic`. Archipelagos sit on shallow
    sandy banks, volcanoes plunge into deep water, and every kind but the continent is its
    own biome.
  - `height`, plus optional `rivers`: file names in `maps/`.
  - `river_mouths`: for a landmass with rivers, where each river system meets the sea
    (world x, z). Only there does its water reach the sea, so a stroke that passes close
    to the coast elsewhere doesn't become a second outlet.
  - `oxbows`: still crescent lakes left by old bends, each a list of world (x, z)
    `points` along its middle and a `half_width` in metres. `tools/erode_maps.py`
    writes these.
- `biomes`: the world-wide biome map, covering the whole 30 km.

To add a landmass, add an entry and its height map.

## The main island's maps: `tools/erode_maps.py`

`maps/src/main_island_painted.png` is the painted original. The tool erodes it
(rivers carving valleys, slopes slumping to a realistic angle), traces a river
tree from where water actually drains, adds meanders and oxbows, and writes
`main_island_height.png`, `main_island_rivers.png` and the layout's `oxbows`.
Paint changes into the original, then run `python3 tools/erode_maps.py` (it
needs numpy, scipy, pillow and numba).

## Height maps: `*_height.png`

16-bit grayscale. In Krita: Image > Convert Image Color Space > Grayscale/Alpha, 16-bit
integer/channel. Export as PNG. 8-bit also works, but it terraces the slopes.

- Black is sea. The seafloor is made automatically from the distance to the coast.
- Anything brighter is land: `sea_value` is the shoreline and white is `peak` metres.
- Paint the big shapes only: ranges, plateaus, lowlands, slopes down to the shore. The
  fine detail (gullies, spurs, mesa cliffs, river valleys, dunes) is added by the game.
- Soft brushes give soft hills, hard edges give cliffs. Blur a little to remove brush
  marks.

## River map: `main_island_rivers.png`

White strokes on black, a few pixels wide. Each connected set of strokes becomes one
river system that drains out through its mouth (`river_mouths` in the layout). Water
follows the strokes down to the mouth, so every branch becomes a tributary. Don't close
loops, because a river can't split. Widths come from how much land drains into each
river, so you don't paint them. The game draws each river's water as a ribbon along its
channel. Its ripples stream downstream around every bend, at the river's speed.

## Biome map: `world_biomes.png`

The whole world, in flat colours. Turn antialiasing off, or at least keep the colours
pure. Paint over the sea as well as the land. The archipelagos, the volcanic chain and
the peripheral island are each their own biome wherever nothing is painted (paint over
their water for reefs or kelp; their land always stays their own).

| colour | RGB | biome |
|---|---|---|
| brown-orange | 176 112 48 | mesa (tablelands and canyons) |
| red | 205 45 45 | plains (gentle rolling ground) |
| dark purple | 96 36 100 | forest (hillier ground) |
| teal | 40 175 150 | riparian wetlands (low, flat, hollows and pools) |
| hot purple | 150 20 190 | coral reef (coral heads on the seafloor) |
| green | 60 150 50 | kelp forest (rocky seafloor) |
| cyan | 0 255 242 | root maze (shallows by the shore, channels) |
| black | 0 0 0 | nothing in particular |

The same colours mark the biomes on the terrain for now.
