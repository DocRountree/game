"""The generator's settings and shared helpers: the world's size and grids,
the seed (WORLD_SEED, default 7), where it writes (world/, or WORLD_OUT)
and log()."""
import json, math, os, sys, time, zlib
import numpy as np
from PIL import Image
from scipy import ndimage
from numba import njit

REPO_WORLD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "world") + "/"
ROOT = os.environ.get("WORLD_OUT", REPO_WORLD).rstrip("/") + "/"   # (where it writes: world/ unless WORLD_OUT says)
SCHEMA = REPO_WORLD + "schema.json"
os.makedirs(ROOT, exist_ok=True)
SEED = int(os.environ.get("WORLD_SEED", "7"))
WORLD = 20480.0                 # m; the world is the square +-WORLD/2, origin at its centre
N = 8192                        # final grid: 2.5 m
M = 2048                        # coarse grid: 10 m
MID = 4096                      # droplet grid: 5 m
H_MIN, H_MAX = -300.0, 1100.0   # the uint16 range (2 cm steps)
T0 = time.time()


def log(*a):
    print("[%5.1fs]" % (time.time() - T0), *a, file=sys.stderr, flush=True)


NB = np.array([(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)], np.int64)
ND = np.array([math.sqrt(2), 1, math.sqrt(2), 1, 1, math.sqrt(2), 1, math.sqrt(2)])
