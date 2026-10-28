# The world's maps

The world is built from these hand-painted maps. Edit them in Krita (or GIMP),
save, and the game re-bakes the world the next time it starts. If the change
doesn't show, delete the cached bake: `~/.local/share/godot/app_userdata/<project>/worlds/`
on Linux, `%APPDATA%\Godot\app_userdata\<project>\worlds\` on Windows. Or bump
`WorldBake.VERSION`.

This folder has a `.gdignore`, so Godot doesn't import these files. The bake
reads the PNGs directly, so 16-bit heights keep their full precision.

## Layout: `layout.json`

- `world_size`: the world is a square this many metres across (30000). The origin is its
  centre, x runs east and z south, so north is -z.
- `sea_value`: in height maps, values at or below this are sea (0.02).
- `spawn`: where the player starts, world x and z. Put it in open water.
- `landmasses`: each one names its maps and places them:
  - `center` (x, z) and `size`: the square of the world the maps cover, in metres.
  - `peak`: the height in metres that pure white means.
  - `kind`: `continent`, `island`, `archipelago` or `volcanic`. Archipelagos sit on shallow
    sandy banks, volcanoes plunge into deep water, and every kind but the continent is its
    own biome.
  - `height`, plus optional `rivers` and `biomes`: file names in `maps/`.

To add a landmass, add an entry and its height map.

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
river system. Water follows the strokes down to the sea, so draw from the mouth up into
the hills and make sure each system touches the coast once. Branches become tributaries.
Widths come from how much land drains into each river, so you don't paint them.

## Biome map: `main_island_biomes.png`

Flat colours. Turn antialiasing off, or at least keep the colours pure.

| colour | RGB | biome |
|---|---|---|
| orange | 255 115 0 | mesa (tablelands and canyons) |
| pink | 255 102 200 | prairie (gentle rolling ground) |
| purple | 133 51 255 | forest (hillier ground) |
| yellow | 255 237 0 | coral reef (coral heads on the seafloor) |
| cyan | 0 255 242 | root maze (shallows by the shore, channels) |
| red | 255 20 38 | kelp forest (rocky seafloor) |
| black | 0 0 0 | nothing in particular |

Paint the sea biomes onto the water around the island. The same colours mark the biomes
on the terrain for now.
