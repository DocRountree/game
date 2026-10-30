"""Erosion at 10 m: stream power (the drainage, ridges and valleys), with
talus and a little diffusion near the coasts."""
from .config import *
from .kernels import *

INPUTS = ['CELL', 'h', 'land']
OUTPUTS = ['CELL', 'h']


def run(ctx):
    CELL = ctx['CELL']
    h = ctx['h']
    land = ctx['land']
    h0 = h.copy()
    he = h.copy()
    for it in range(45):
        recv, order = flood_route(he, land, 1e-4)
        recv = steepest(he, land, order, recv, True, SEED * 100 + it)
        area = accumulate(order, recv, land, CELL * CELL)
        he = stream_power(he, land, order, recv, area, 3.0e-5, 400.0, CELL)
        he = diffuse(he, land, 0.05, 1)
    # keep the large-scale shape: rescale the eroded relief so its smoothed
    # envelope matches the original's (erosion adds the valleys and spurs between)
    env0 = ndimage.gaussian_filter(np.where(land, h0, 0.0), 12)
    env1 = ndimage.gaussian_filter(np.where(land, he, 0.0), 12)
    ratio = np.clip(np.where(env1 > 1.0, env0 / np.maximum(env1, 1.0), 1.0), 0.6, 1.9)
    coast = ndimage.distance_transform_edt(land) * CELL
    w = np.clip(coast / 250.0, 0, 1)
    hl = he * ratio * w + h0 * (1 - w)
    h = np.where(land, np.maximum(hl, 0.4), h)
    h = talus(h, land, CELL, math.tan(math.radians(40.0)), 20)
    # the coast smoothed over 40 m either side, so the shoreline is a curve, not
    # the 10 m cells' staircase (land is held just above the sea, the sea isn't)
    near_coast = np.minimum(ndimage.distance_transform_edt(land), ndimage.distance_transform_edt(~land)) * CELL
    h = h + (ndimage.gaussian_filter(h, 1.5) - h) * np.clip(1.0 - near_coast / 40.0, 0, 1)
    del near_coast
    log("stream power; max %.0f m" % h.max())
    return {'CELL': CELL, 'h': h}
