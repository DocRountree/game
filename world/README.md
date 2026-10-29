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
   mountain range off-centre down its spine (peaks around 800 m: heights above 40 m are
   raised by up to a third before erosion) and a main valley along its
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
   (by the biggest donor) to where it starts. Smoothed over about its own width (no jogs
   from the grid it was traced on), meandering where the valley floor is flat (never so
   much round a bend that the course folds over itself). A tributary keeps its own course
   only until it first comes within reach of its river (the river's floodplain), so it
   never runs along beside it; from there it heads in and crosses the bank at 30-45
   degrees, easing in alongside to meet it on its centreline. Streams that would be only
   stubs that way (their whole valley beside their river) are left out. Across its river's
   floodplain a tributary lies no higher than the floodplain, and it ends at its river's
   level; it is brought down to those gently (the lowering spread back up its course at
   1 cm a metre), never in a step at the floodplain or the confluence. No centreline doubles back on itself or bends tighter
   than a radius of 2.5 half widths. Widths are set for game scale (9 m wide at the heads,
   about 130 m at the mouth, where the trunk opens out into the sea over its last 500 m),
   and depths too (1.6 m at the heads to 7 m, shoaling to about 3 m at the mouth). The
   trunk ends in an estuary: over its last 1.5 km it comes down to the sea gently (2.2 m
   per km, 0.05 m at the coast; the lowering that needs is eased out up its course at 1 cm
   a metre, and above that it keeps its natural fall), its valley floor with it and its
   banks low by the sea; its channel is carried on 400 m out to sea through the low beach
   and bar there, so nothing stands between it and the sea. The
   water level is the downhill profile closest to the ground, smoothed into one continuous
   run of gentle reaches and rapids. Each tributary gets a waterfall where the ground drops
   steeply (the most over 144 m, at least 12 m; a second only for 40 m or more), and a side
   valley hanging more than 6 m above its river's floodplain drops the rest in one where it
   meets it. Each fall is one steep drop: the water held to its lip (running shallow over
   the last stretch before it, the bed rising to the brink), then down the face (rounded
   over the lip and into its foot, as steep as the 2.5 m grid draws cleanly: its run 0.3
   of its height, at least 3 m) into a plunge pool at its foot, wider and deeper (most in
   the lowlands) right from the foot, so water coming down any part of the face lands in it. The face is sampled finely (a point every 0.25 m of the drop) so
   the carve cuts it cleanly; the points say how far down a face each is ("riser"), and
   each fall's first and last point are listed ("falls"). The game breaks the water down
   the face into separate streams over light terracing (see docs/ARCHITECTURE.md). Where the trunk runs wide and gentle in
   the lowlands (away from the mouth and its confluences) it parts round a few islands:
   teardrops of sand and grass, blunt upstream and tapering downstream, smooth mounds whose
   feet slope on down into the bed (no step, so their shores are smooth; well past an
   island they drop away, never left standing across the lower river), the channel opening
   out round each (listed in world.json as "islands"). The bed, banks and floodplain are carved into the
   2.5 m heights to match, so the water always lies in its bed: each river's ground is one
   continuous field (nearby reaches blended), the floodplain wide in the lowlands and none
   beside mountain streams (their banks meet the valley's own sides, which are left as they
   are), the sides laid back in a V wherever a river runs below the ground (below a fall),
   and beyond the banks the ground only ever lowered, never built up (easing over to that
   between 1.3 and 2.4 half widths out, with no step where it starts); the banks never
   stand lower than the water nearest them, higher down a cascade (a channel of rock, cut
   sharply so the drop is clean). Where valleys overlap the river with the stronger claim
   takes over smoothly; every channel is then cut through the others' banks, so a
   tributary keeps its width right into its river (the cut easing off over its banks).
   Last, the ground beside every channel is lightly smoothed (not in the water, nor down a
   cascade), so no step or sawtooth is left along a bank, and held above the water again.
   Mountaintops are made a little rounder (narrow crests and spines eased) so they can be
   stood on, and river banks are never steeper than the 2.5 m grid draws smoothly.
5. **Masks and trees**: rock on steep and high ground, sand on beaches, the seafloor and
   the rivers' beds,
   forest in clumps on gentle slopes below 700 m, ambient occlusion from the hollows; trees
   scattered by the forest mask.
6. **Start**: a beach on the main island near the river mouth, the boat in 7 m of water
   offshore.
