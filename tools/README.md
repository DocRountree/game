# Tools

Scripts for building, exporting and testing. Godot does not scan this folder.

| Script | Purpose |
|---|---|
| `run_tests.sh` | Runs the headless tests in `tests/`. Uses `godot` on PATH or `$GODOT`. |
| `gen_world.py` | Generates the test world of islands into `world/` from a seed (`python3 tools/gen_world.py [seed]`, about a minute; needs numpy, scipy, pillow and numba). See `world/README.md`. |
