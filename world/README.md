# The generated world

Everything here is written by `tools/gen_world.py` (`python3 tools/gen_world.py [seed]`,
about a minute; it needs numpy, scipy, pillow and numba). Change the seed for a
different world. The folder has a `.gdignore`, so Godot doesn't import these
files: the game reads them directly (`WorldData`).

The world is 20480 m square, centred on the origin (x east, z south). Height
sample i sits at -5120 + 2.5 i metres.

| File | What |
|---|---|
| `height_hi.bin`, `height_lo.bin` | zlib-compressed byte planes of the 16-bit heights (8192 x 8192, -300 m to 1100 m in 2 cm steps), each followed by its mips down to 1 x 1 (mip k: means of 2^k x 2^k samples). Two planes compress far better than interleaved 16-bit values, and the GPU reads them as two R8 textures. |
| `ground.png` | 4096 x 4096 RGBA masks: rock, sand, forest density, ambient occlusion. |
| `trees.bin` | zlib: 8 bytes per stand-in tree: uint16 x and z (over the world), uint16 ground height (encoded as the heights), uint8 height (decimetres), uint8 spare. |
| `world.json` | seed, sizes, height range, spawn and mooring, landmasses, and the rivers (centreline points with their water level, half widths, depths, which river each one joins). |

How it's made:

1. **Layout** (10 m grid): a main island about 11 km across in the north-west, with a
   mountain range off-centre down its spine (peaks around 600 m) and a main valley along its
   wide side; an archipelago of about 150 low, smooth islands of very varied size (mostly
   50-500 m across) in a broad band east of it; a peripheral island far off to the
   north-east; a southern group on a wide bank south of the gap; a chain of volcanic cones
   with craters to the south-east, growing toward the east. Positions are fixed in outline
   and jittered by the seed; coasts turn back short of the world's edge. Each is an elevation field with its own wobbled,
   stretched coastline.
2. **Seafloor**: shelves by distance from the coast, shallow sandy banks under the
   archipelago and the southern group, deep water round the volcanoes.
3. **Erosion** at three scales: stream-power erosion at 10 m (the drainage, ridges and
   valleys, keeping the big shapes), droplet erosion at 5 m (gullies; sediment settles into
   flat valley floors and fans), fine detail and a talus pass at 2.5 m.
4. **Rivers**: the main island's biggest catchment drains through one mouth. The system is
   built as a drainage hierarchy: the trunk traced up from the mouth, its six biggest side
   branches and up to two branches off each of those, every stream traced up its own valley
   (by the biggest donor) to where it starts. Smoothed, meandering where the valley floor is
   flat; each tributary's last stretch curves round into its river's downstream direction
   and meets it on its centreline. Widths are set for game scale (9 m wide at the heads,
   about 130 m at the mouth), and depths too (1.6 m at the heads to 7 m at the mouth). The
   water level is the downhill profile closest to the ground, smoothed into one continuous
   run of gentle reaches and rapids. Each tributary gets at most one waterfall, at its
   steepest spot where the ground drops at least 8 m over 60 m: the pool below is carried
   back under the slope to a lip and the water drops sheer into a plunge pool. The bed, banks and floodplain are carved into the
   2.5 m heights to match, so the water always lies in its bed: each river's ground is one
   continuous field (nearby reaches blended), the floodplain wide in the lowlands and narrow
   beside mountain streams, and where valleys overlap the river with the stronger claim
   takes over smoothly.
5. **Masks and trees**: rock on steep and high ground, sand on beaches and the seafloor,
   forest in clumps on gentle slopes below 700 m, ambient occlusion from the hollows; trees
   scattered by the forest mask.
6. **Start**: a beach on the main island near the river mouth, the boat in 7 m of water
   offshore.
