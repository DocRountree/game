# Tools

Scripts for building, exporting and testing. Godot does not scan this folder.

| Script | Purpose |
|---|---|
| `run_tests.sh` | Runs the headless tests in `tests/`. Uses `godot` on PATH or `$GODOT`. |
| `gen_world.py` | Generates the test world of islands into `world/` from a seed (`python3 tools/gen_world.py [seed]`, about a minute; needs numpy, scipy, pillow and numba). See `world/README.md`. |
| `bench/run.sh TAG [views]` | Renders the benchmark views of the debug world (headwater, rapids, lowland, island, mouth, the tallest fall from the front, pool, lip, above and low, upstream of it, the open sea) into `bench/out/TAG/`, each with a mask of the rivers' water, at a fixed 60 fps so runs compare frame for frame; writes each view's GPU/CPU ms, draw calls and triangles (`report.jsonl`) and image metrics (`metrics.json`: the water's mean CIELAB colour, brightest pixel, coverage). `GODOT=… FRAMES=120 MASKS=0`. GPU times are only meaningful on real hardware. |
