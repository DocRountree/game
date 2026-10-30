"""The seafloor: shelving away from the coasts, a shallow sandy bank under the
archipelago and the southern group, deep water round the volcanoes."""
from .config import *
from .kernels import *

INPUTS = ['CELL', 'H', 'X', 'Z', 'arc_pts', 'south', 'volcano_centres']
OUTPUTS = ['CELL', 'h', 'land']


def run(ctx):
    CELL = ctx['CELL']
    H = ctx['H']
    X = ctx['X']
    Z = ctx['Z']
    arc_pts = ctx['arc_pts']
    south = ctx['south']
    volcano_centres = ctx['volcano_centres']
    land = H > 0.0
    D = ndimage.distance_transform_edt(~land) * CELL
    sea = -(2.0 + 18.0 * np.clip(D / 350.0, 0, 1)) - 60.0 * np.clip((D - 300.0) / 1200.0, 0, 1) \
        - 150.0 * np.clip((D - 1200.0) / 2300.0, 0, 1)
    sea += 4.0 * field_fbm(X, Z, 500.0, 3, SEED + 7) * np.clip(D / 200.0, 0, 1)
    # the archipelago's and the southern group's shallow sandy banks
    def near_pts(pts, scale):
        best = np.full((M, M), 1e9)
        for p in pts:
            best = np.minimum(best, np.hypot(X - p[0], Z - p[1]))
        return np.exp(-(best / scale) ** 2)
    bank = np.maximum(near_pts(arc_pts, 1400.0), near_pts(south, 1300.0) if south else 0.0)
    sea = sea * (1.0 - bank) + bank * np.maximum(sea, -5.0 - 7.0 * (field_fbm(X, Z, 300.0, 3, SEED + 8) * 0.5 + 0.5))
    # volcanoes plunge into deep water
    vm = np.zeros((M, M))
    for cx, cz, r in volcano_centres:
        vm = np.maximum(vm, np.exp(-(np.maximum(np.hypot(X - cx, Z - cz) - r, 0) / 700.0) ** 2))
    sea = sea * (1.0 - vm) + vm * np.minimum(sea, -15.0 - 240.0 * np.clip(D / 550.0, 0, 1))
    h = np.where(land, np.maximum(H, 0.4), sea)
    log("seafloor; land %.1f km2" % (land.sum() * CELL * CELL / 1e6))
    return {'CELL': CELL, 'h': h, 'land': land}
