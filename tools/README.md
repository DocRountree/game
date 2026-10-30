# Tools

Scripts for building, exporting and testing. Godot does not scan this folder.

| Script | Purpose |
|---|---|
| `run_tests.sh` | Runs the headless tests in `tests/`. Uses `godot` on PATH or `$GODOT`. |
| `worldgen/` | Generates the test world of islands into `world/` from a seed: `python3 -m tools.worldgen [--seed N] [--cache] [--until STAGE] [--out DIR]` from the repository's root (about eight minutes; needs numpy, scipy, pillow and numba). A pipeline of stage modules (`s01_layout` ... `s14_write`), each with its `INPUTS`, `OUTPUTS` and `run(ctx)`; shared functions in `kernels.py`, settings in `config.py`. With `--cache` each stage's output is kept (`.cache/`, keyed by the seed and the source of that stage and those before it), so a run starts from the last unchanged stage: tweaking the falls doesn't rerun erosion. Writes the format in `world/schema.json`. See `world/README.md`. |
| `bench/run.sh TAG [views]` | Renders the benchmark views of the debug world (headwater, rapids, lowland, island, mouth, the tallest fall from the front, pool, lip, above and low, upstream of it, the open sea) into `bench/out/TAG/`, each with a mask of the rivers' water, at a fixed 60 fps so runs compare frame for frame; writes each view's GPU/CPU ms, draw calls and triangles (`report.jsonl`) and image metrics (`metrics.json`: the water's mean CIELAB colour, brightest pixel, coverage). `GODOT=… FRAMES=120 MASKS=0`. GPU times are only meaningful on real hardware. |
