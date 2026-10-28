# The generated world

Everything here is written by `tools/gen_world.py` (`python3 tools/gen_world.py [seed]`,
about a minute; it needs numpy, scipy, pillow and numba). Change the seed for a
different world. The folder has a `.gdignore`, so Godot doesn't import these
files: the game reads them directly (`WorldData`).

The world is 10240 m square, centred on the origin (x east, z south). Height
sample i sits at -5120 + 2.5 i metres.

| File | What |
|---|---|
| `height_hi.bin`, `height_lo.bin` | zlib-compressed byte planes of the 16-bit heights (4096 x 4096, -300 m to 1100 m in 2 cm steps), each followed by its mips down to 1 x 1 (mip k: means of 2^k x 2^k samples). Two planes compress far better than interleaved 16-bit values, and the GPU reads them as two R8 textures. |
| `ground.png` | 2048 x 2048 RGBA masks: rock, sand, forest density, ambient occlusion. |
| `trees.bin` | zlib: 6 bytes per stand-in tree: uint16 x and z (over the world), uint8 height (decimetres), uint8 spare. |
| `world.json` | seed, sizes, height range, spawn and mooring, landmasses, and the rivers (centreline points with their water level, half widths, depths, which river each one joins). |

How it's made:

1. **Layout** (10 m grid): a main island about 5.5 km across with a mountain range off-centre
   down its spine (peaks 600-900 m) and a main valley along its wide side; a peripheral
   island; an archipelago of about 90 small islands along an arc; a chain of volcanic cones
   with craters; a southern group. Each is an elevation field with its own wobbled,
   stretched coastline.
2. **Seafloor**: shelves by distance from the coast, shallow sandy banks under the
   archipelago and the southern group, deep water round the volcanoes.
3. **Erosion** at three scales: stream-power erosion at 10 m (the drainage, ridges and
   valleys, keeping the big shapes), droplet erosion at 5 m (gullies; sediment settles into
   flat valley floors and fans), fine detail and a talus pass at 2.5 m.
4. **Rivers**: traced from the eroded drainage of the main island's biggest catchment (a
   trunk and about a dozen tributaries), smoothed, meandering where the valley floor is
   flat. Widths are set for game scale (9 m wide at the heads, 60 m at the mouth). The water
   level is the downhill profile closest to the ground, and the bed, banks and floodplain
   are carved into the 2.5 m heights to match it, so the water always lies in its bed.
5. **Masks and trees**: rock on steep and high ground, sand on beaches and the seafloor,
   forest in clumps on gentle slopes below 700 m, ambient occlusion from the hollows; trees
   scattered by the forest mask.
6. **Start**: a beach on the main island near the river mouth, the boat in 7 m of water
   offshore.
