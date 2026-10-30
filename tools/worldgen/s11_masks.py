"""The ground masks (ground.png): rock on steep and high ground, sand on the
beaches and the rivers' beds and banks, forest density, ambient occlusion."""
from .config import *
from .kernels import *

INPUTS = ['BED', 'Wt', 'hf']
OUTPUTS = ['cellg', 'forest', 'hf', 'hg', 'land_g', 'river_r', 'sea_d', 'slope']


def run(ctx):
    BED = ctx['BED']
    Wt = ctx['Wt']
    hf = ctx['hf']
    G = N // 2
    hg = hf.reshape(G, 2, G, 2).mean(axis=(1, 3))
    XG, ZG = world_coords(G)
    cellg = WORLD / G
    gy, gx = np.gradient(hg, cellg)
    slope = np.degrees(np.arctan(np.hypot(gx, gy)))
    land_g = hg > 0.0
    sea_d = ndimage.distance_transform_edt(land_g) * cellg
    river_r = Wt.reshape(G, 2, G, 2).max(axis=(1, 3))   # how much of the ground is a river's
    rock = np.clip((slope - 30.0) / 10.0, 0, 1)
    rock = np.maximum(rock, np.clip((hg - 760.0) / 140.0, 0, 1) * np.clip((slope - 18.0) / 10.0, 0, 1))
    sand = np.where(land_g, np.clip(1.0 - (hg - 1.5) / 2.5, 0, 1) * np.clip(1.0 - (sea_d - 25.0) / 50.0, 0, 1), 1.0)
    sand = np.maximum(sand, np.where(land_g, 0.0, 1.0))
    # the rivers' beds and banks are sand and gravel (so the bed shows through
    # the water, right to its edge)
    bed = ndimage.gaussian_filter(BED.reshape(G, 2, G, 2).mean(axis=(1, 3)), 0.8)
    sand = np.maximum(sand, np.clip(bed * 1.2, 0, 1) * 0.85)
    del BED   # (channel: an earlier stage's)
    clump = field_fbm(XG, ZG, 650.0, 4, SEED + 11) + 0.35 * field_fbm(XG, ZG, 120.0, 3, SEED + 12)
    forest = np.clip((clump + 0.15) / 0.45, 0, 1) * np.clip(1.0 - (slope - 24.0) / 10.0, 0, 1) \
        * np.clip((hg - 4.0) / 6.0, 0, 1) * np.clip(1.0 - (hg - 560.0) / 160.0, 0, 1) \
        * (1.0 - sand) * (1.0 - np.clip((river_r - 0.55) / 0.25, 0, 1))
    c1 = ndimage.gaussian_filter(hg, 3) - hg
    c2 = ndimage.gaussian_filter(hg, 14) - hg
    occl = np.clip(0.5 * c1 / 2.0 + 0.5 * c2 / 12.0, 0, 1)
    ao = 1.0 - 0.65 * occl
    img = np.stack([rock, sand, forest, ao], -1)
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA").save(ROOT + "ground.png", optimize=True)
    log("masks")
    return {'cellg': cellg, 'forest': forest, 'hf': hf, 'hg': hg, 'land_g': land_g, 'river_r': river_r, 'sea_d': sea_d, 'slope': slope}
