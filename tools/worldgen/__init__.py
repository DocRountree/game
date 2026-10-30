"""World generator (not part of the game): python3 -m tools.worldgen [--seed N] [--cache]

Makes the 20 x 20 km test world of islands from a seed and writes it to
world/ in the format world/schema.json describes, for the game to load
(WorldData). A pipeline of stages (STAGES, in order), each a module with
INPUTS (the names it reads from the ones before it), OUTPUTS (what it hands
on) and run(ctx) -> {name: value}:

  layout, seafloor      the islands at 10 m: a main island with a range and one
                        river system, a peripheral island, an archipelago on a
                        sandy bank, volcanic cones, a southern group; the seafloor
  erosion_10m           stream-power erosion (drainage, ridges, valleys)
  erosion_5m            droplet erosion (gullies, valley floors, fans)
  fine_detail           2.5 m detail and talus
  rivers_trace          the river system traced from the drainage
  river_levels          widths, depths and water levels
  falls                 each waterfall one steep drop, sampled down its face
  islands               islands in the trunk where it runs wide and gentle
  carve                 the rivers carved into the 2.5 m heights with their water
  masks, trees, spawn   ground masks, stand-in trees, where to start
  write                 world/ (stamped with the schema's version)

With --cache each stage's hand-on is kept in tools/worldgen/.cache, keyed by
the seed and the source of that stage and every one before it, so a run
starts from the last stage whose inputs haven't changed (tweaking the falls
doesn't rerun erosion). Needs numpy, scipy, pillow and numba.
"""
