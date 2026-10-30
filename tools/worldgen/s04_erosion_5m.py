"""Erosion at 5 m: droplets carving gullies, their sediment settling into flat
valley floors and fans (the islets kept smooth)."""
from .config import *
from .kernels import *

INPUTS = ['h', 'islet_ids', 'owner']
OUTPUTS = ['hm', 'islet_m', 'owner']


def run(ctx):
    h = ctx['h']
    islet_ids = ctx['islet_ids']
    owner = ctx['owner']
    hm = resize(h, MID)
    xs_m = np.arange(MID) / MID * WORLD - WORLD / 2
    land_m = hm > 0.0
    slope_m = np.hypot(*np.gradient(hm, WORLD / MID))
    # the archipelago's islets stay low and smooth (no ridges, no gullies)
    islet = np.isin(owner, islet_ids)
    islet_m = ndimage.gaussian_filter(islet.repeat(2, 0).repeat(2, 1).astype(np.float32), 3.0)
    # mid-scale detail on the slopes before the droplets run: they cut it into gullies
    hm += np.where(land_m, (grid_ridged(xs_m, xs_m, 160.0, 3, SEED + 9) - 0.4) * 14.0 * np.clip(slope_m / 0.4, 0, 1)
                   * np.clip(hm / 30.0, 0, 1) * (1.0 - islet_m), 0.0)
    del slope_m
    hm = droplets(hm, 3600000, SEED, WORLD / MID)
    hm = np.where(land_m, hm * (1.0 - islet_m) + ndimage.gaussian_filter(hm, 4.0) * islet_m, hm)
    log("droplets; max %.0f m" % hm.max())
    return {'hm': hm, 'islet_m': islet_m, 'owner': owner}
