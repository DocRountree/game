"""Run the world generator's pipeline (see __init__.py)."""
import argparse, hashlib, importlib, inspect, os, pickle, sys, time

STAGES = ["s01_layout", "s02_seafloor", "s03_erosion_10m", "s04_erosion_5m", "s05_fine_detail",
          "s06_rivers_trace", "s07_river_levels", "s08_falls", "s09_islands", "s10_carve",
          "s11_masks", "s12_trees", "s13_spawn", "s14_write"]
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python3 -m tools.worldgen", description=__doc__)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--cache", action="store_true", help="keep each stage's output and start from the last unchanged one")
    ap.add_argument("--until", help="stop after this stage (e.g. s09_islands)")
    ap.add_argument("--out", help="write the world here instead of world/")
    args = ap.parse_args(argv)
    os.environ["WORLD_SEED"] = str(args.seed)
    if args.out:
        os.environ["WORLD_OUT"] = args.out
    from . import config
    common = "".join(open(os.path.join(HERE, f)).read() for f in ("config.py", "kernels.py")) + str(args.seed)
    keys, h = [], hashlib.sha256(common.encode())
    for name in STAGES:
        h = h.copy()
        h.update(open(os.path.join(HERE, name + ".py")).read().encode())
        keys.append(h.hexdigest()[:16])
    ctx, start = {"rng": __import__("numpy").random.default_rng(args.seed)}, 0
    if args.cache:
        os.makedirs(CACHE, exist_ok=True)
        for i in range(len(STAGES) - 2, -1, -1):
            path = os.path.join(CACHE, "%s_%s.pkl" % (STAGES[i], keys[i]))
            if os.path.exists(path):
                config.log("from the cache: everything up to", STAGES[i])
                ctx = pickle.load(open(path, "rb"))
                start = i + 1
                break
    for i in range(start, len(STAGES)):
        stage = importlib.import_module("." + STAGES[i], __package__)
        missing = [k for k in stage.INPUTS if k not in ctx]
        if missing:
            raise SystemExit("%s needs %s, which no stage before it made" % (STAGES[i], missing))
        out = stage.run(ctx)
        ctx.update(out)
        # (only what later stages still read is kept)
        later = set().union(*[importlib.import_module("." + s, __package__).INPUTS for s in STAGES[i + 1:]]) if i + 1 < len(STAGES) else set()
        ctx = {k: v for k, v in ctx.items() if k in later}
        if args.cache and i + 1 < len(STAGES):
            for old in os.listdir(CACHE):
                if old.startswith(STAGES[i] + "_"):
                    os.remove(os.path.join(CACHE, old))
            pickle.dump(ctx, open(os.path.join(CACHE, "%s_%s.pkl" % (STAGES[i], keys[i])), "wb"), protocol=4)
        if args.until and STAGES[i] == args.until:
            break


if __name__ == "__main__":
    main()
