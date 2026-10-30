"""Where to start: a beach on the main island near the river mouth, and the
boat moored offshore in at least 7 m of water."""
from .config import *
from .kernels import *

INPUTS = ['CELL', 'cellg', 'hg', 'land_g', 'main_id', 'mouth', 'owner', 'river_r', 'sea_d', 'slope']
OUTPUTS = ['boat', 'spot']


def run(ctx):
    CELL = ctx['CELL']
    cellg = ctx['cellg']
    hg = ctx['hg']
    land_g = ctx['land_g']
    main_id = ctx['main_id']
    mouth = ctx['mouth']
    owner = ctx['owner']
    river_r = ctx['river_r']
    sea_d = ctx['sea_d']
    slope = ctx['slope']
    mw = np.array([mouth[1] * CELL - WORLD / 2, mouth[0] * CELL - WORLD / 2])
    owner_g = owner.repeat(2, 0).repeat(2, 1)
    cand = np.argwhere(land_g & (hg > 1.2) & (hg < 6.0) & (slope < 8.0) & (river_r < 0.05) & (sea_d < 60) & (owner_g == main_id))
    pos = (cand[:, ::-1] + 0.25) * cellg - WORLD / 2   # (mask cells are 2 x 2 means of the samples)
    dd = np.linalg.norm(pos - mw, axis=1)
    okc = (dd > 400) & (dd < 1800)
    spot = pos[okc][np.argmin(np.abs(dd[okc] - 800))] if okc.any() else pos[np.argmin(dd)]
    # the boat: the nearest point at least 7 m deep, seaward
    deep = np.argwhere(hg < -7.0)
    dpos = (deep[:, ::-1] + 0.25) * cellg - WORLD / 2
    boat = dpos[np.argmin(np.linalg.norm(dpos - spot, axis=1))]
    boat = spot + (boat - spot) * 1.1
    return {'boat': boat, 'spot': spot}
