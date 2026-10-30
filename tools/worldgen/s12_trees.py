"""The stand-in trees (trees.bin), scattered by the forest mask."""
from .config import *
from .kernels import *

INPUTS = ['forest', 'hf', 'rng']
OUTPUTS = ['hf', 'rng', 'tx']


def run(ctx):
    forest = ctx['forest']
    hf = ctx['hf']
    rng = ctx['rng']
    STEP = 7.0
    gxs = np.arange(-WORLD / 2 + STEP / 2, WORLD / 2, STEP)
    TX, TZ = np.meshgrid(gxs, gxs)
    TX = TX + rng.uniform(-0.45, 0.45, TX.shape) * STEP
    TZ = TZ + rng.uniform(-0.45, 0.45, TZ.shape) * STEP
    fd = bilinear(forest, TX, TZ)
    keep = rng.random(TX.shape) < fd * 0.8
    tx, tz = TX[keep], TZ[keep]
    th = np.clip(rng.lognormal(math.log(14.0), 0.25, tx.size), 7.0, 25.0)
    q = lambda v: np.clip((v + WORLD / 2) / WORLD * 65535.0, 0, 65535).astype(np.uint16)
    ty = bilinear(hf, tx, tz)
    rec = np.zeros(tx.size, dtype=[("x", "<u2"), ("z", "<u2"), ("y", "<u2"), ("h", "u1"), ("s", "u1")])
    rec["x"] = q(tx); rec["z"] = q(tz); rec["h"] = np.clip(th * 10.0, 0, 255).astype(np.uint8)
    rec["x"] = q(tx); rec["z"] = q(tz); rec["h"] = np.clip(th * 10.0, 0, 255).astype(np.uint8)
    rec["x"] = q(tx); rec["z"] = q(tz); rec["h"] = np.clip(th * 10.0, 0, 255).astype(np.uint8)
    rec["y"] = np.clip((ty - H_MIN) / (H_MAX - H_MIN) * 65535.0 + 0.5, 0, 65535).astype(np.uint16)
    rec["s"] = rng.integers(0, 256, tx.size).astype(np.uint8)
    open(ROOT + "trees.bin", "wb").write(zlib.compress(rec.tobytes(), 9))
    log("trees:", tx.size)
    return {'hf': hf, 'rng': rng, 'tx': tx}
