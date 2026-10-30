"""The final 2.5 m grid: fine detail on the land (more on steep ground), a
talus pass, and narrow crests eased so mountaintops are something to stand on."""
from .config import *
from .kernels import *

INPUTS = ['hm', 'islet_m']
OUTPUTS = ['hf']


def run(ctx):
    hm = ctx['hm']
    islet_m = ctx['islet_m']
    hf = resize(hm, N)
    del hm
    xs_f = np.arange(N) / N * WORLD - WORLD / 2
    land_f = hf > 0.0
    gy_, gx_ = np.gradient(hf, WORLD / N)
    slope_f = np.hypot(gx_, gy_).astype(np.float32)
    del gy_, gx_
    islet_f = islet_m.repeat(2, 0).repeat(2, 1)
    hf += np.where(land_f, grid_fbm(xs_f, xs_f, 40.0, 3, SEED + 10) * (0.4 + 2.0 * np.clip(slope_f, 0, 1))
                   * np.clip(hf / 4.0, 0, 1) * (1.0 - 0.8 * islet_f), 0.0)
    del slope_f, islet_f
    hf = talus(hf, land_f, WORLD / N, math.tan(math.radians(42.0)), 6)
    # mountaintops a little rounder: narrow crests and spines eased (convex
    # ground only, high up), so their tops are something to stand on
    crest = np.maximum(hf - ndimage.gaussian_filter(hf, 5.0), 0.0)
    hf = hf - 0.6 * crest * np.clip((hf - 80.0) / 120.0, 0, 1)
    del crest
    log("fine detail")
    return {'hf': hf}
