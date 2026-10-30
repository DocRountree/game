"""Write world/: the heights as two zlib'd byte planes with their mips, and
world.json, stamped with world/schema.json's format and version and checked
against its field lists (ground.png and trees.bin are written by masks and
trees)."""
from .config import *
from .kernels import *

INPUTS = ['boat', 'hf', 'islands', 'landmasses', 'rivers', 'spot', 'tx']
OUTPUTS = []


def run(ctx):
    boat = ctx['boat']
    hf = ctx['hf']
    islands = ctx['islands']
    landmasses = ctx['landmasses']
    rivers = ctx['rivers']
    spot = ctx['spot']
    tx = ctx['tx']
    os.makedirs(ROOT, exist_ok=True)
    open(ROOT + ".gdignore", "w").close()
    u = np.clip((hf - H_MIN) / (H_MAX - H_MIN) * 65535.0, 0, 65535)
    his, los = [], []
    lv = u
    while True:
        q16 = np.round(lv).astype(np.uint32)
        his.append((q16 >> 8).astype(np.uint8).tobytes())
        los.append((q16 & 255).astype(np.uint8).tobytes())
        if lv.shape[0] == 1:
            break
        lv = lv.reshape(lv.shape[0] // 2, 2, lv.shape[1] // 2, 2).mean(axis=(1, 3))
    # (two byte planes compress far better than interleaved 16-bit values)
    open(ROOT + "height_hi.bin", "wb").write(zlib.compress(b"".join(his), 9))
    open(ROOT + "height_lo.bin", "wb").write(zlib.compress(b"".join(los), 9))
    if os.path.exists(ROOT + "height.bin"):
        os.remove(ROOT + "height.bin")
    schema = json.load(open(SCHEMA))
    out = {
        "format": schema["format"], "version": schema["version"],
        "seed": SEED, "world_size": WORLD, "texels": N, "h_min": H_MIN, "h_max": H_MAX,
        "spawn": [round(float(spot[0]), 2), round(float(spot[1]), 2)],
        "boat": [round(float(boat[0]), 2), round(float(boat[1]), 2)],
        "trees": int(tx.size),
        "landmasses": landmasses,
        "rivers": [{
            "points": [[round(float(p[0]), 2), round(float(l), 3), round(float(p[1]), 2)] for p, l in zip(rv["pts"], rv["level"])],
            "half_width": [round(float(v), 2) for v in rv["hw"]],
            "depth": [round(float(v), 2) for v in rv["depth"]],
            "riser": [round(float(v), 2) for v in rv["riser"]],
            "falls": rv["falls"],
            "joins": rv["joins"],
        } for rv in rivers],
        "islands": [{k_: round(v_, 2) for k_, v_ in i_.items() if k_ in ("x", "z", "dx", "dz", "length", "width", "top")} for i_ in islands],
    }
    missing = [f for f in schema["required"] if f not in out]
    missing += [f for r in out["rivers"][:1] for f in schema["river_fields"] if f not in r]
    if missing:
        raise SystemExit("world.json would lack %s (world/schema.json)" % missing)
    json.dump(out, open(ROOT + "world.json", "w"), separators=(",", ":"))
    log("written: heights %.1f MB, trees %d, max %.0f m, min %.0f m" % (
        (os.path.getsize(ROOT + "height_hi.bin") + os.path.getsize(ROOT + "height_lo.bin")) / 1e6, tx.size, hf.max(), hf.min()))
    return {}
