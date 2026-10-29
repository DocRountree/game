# World generator (not part of the game): python3 tools/gen_world.py [seed]
# Needs numpy, scipy, pillow and numba. A few minutes and a few GB of memory.
#
# Makes a 20 x 20 km test world of islands from a seed and writes it to
# world/ for the game to load:
#   - a main island (~8 km) with a mountain range down its spine (peaks
#     600-900 m) and one river system, a peripheral island, a long archipelago
#     of low islands on a shallow sandy bank, a chain of volcanic cones in
#     deep water, and a southern group of islands;
#   - eroded at three scales: stream-power erosion at 10 m (the drainage,
#     ridges and valleys), droplet erosion at 5 m (gullies, with sediment
#     settling into flat valley floors and fans), and a talus pass at 2.5 m;
#   - the rivers traced from the eroded drainage and carved into the final
#     2.5 m heights together with their water level, so the water always lies
#     in its bed: the bed, the banks and a flat floodplain blending out into
#     the valley; steep mountain stretches step down in pools and waterfalls,
#     and tributaries curve into the river they join;
#   - masks for the ground (rock, sand, forest, ambient occlusion) and the
#     stand-in trees (triangles) scattered by the forest mask.
#
# Outputs (world/, which Godot doesn't import):
#   height_hi.bin, height_lo.bin   zlib: the high and low bytes of uint16
#                heights, 8192 x 8192 and every mip down to 1 x 1
#   ground.png   4096 x 4096 RGBA: rock, sand, forest density, ambient occlusion
#   trees.bin    zlib: per tree uint16 x, uint16 z, uint16 ground height (as
#                the heights), uint8 height (dm), uint8 spare
#   world.json   sizes, height range, rivers, spawn, landmasses
import json, math, os, sys, time, zlib
import numpy as np
from PIL import Image
from scipy import ndimage
from numba import njit

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "world") + "/"
os.makedirs(ROOT, exist_ok=True)
SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 7
WORLD = 20480.0                 # m; the world is the square +-WORLD/2, origin at its centre
N = 8192                        # final grid: 2.5 m
M = 2048                        # coarse grid: 10 m
MID = 4096                      # droplet grid: 5 m
H_MIN, H_MAX = -300.0, 1100.0   # the uint16 range (2 cm steps)
T0 = time.time()
rng = np.random.default_rng(SEED)


def log(*a):
    print("[%5.1fs]" % (time.time() - T0), *a, file=sys.stderr, flush=True)


NB = np.array([(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)], np.int64)
ND = np.array([math.sqrt(2), 1, math.sqrt(2), 1, 1, math.sqrt(2), 1, math.sqrt(2)])


# --- noise -------------------------------------------------------------------

@njit(cache=True)
def _hash(ix, iy, seed):
    h = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return (h ^ (h >> 16)) & 0xFFFFFFFF


@njit(cache=True)
def _gdot(ix, iy, fx, fy, seed):
    a = _hash(ix, iy, seed) * (6.283185307179586 / 4294967296.0)
    return math.cos(a) * fx + math.sin(a) * fy


@njit(cache=True)
def noise(x, y, seed):
    """Gradient noise, about -0.7..0.7."""
    ix = math.floor(x)
    iy = math.floor(y)
    fx = x - ix
    fy = y - iy
    ix = np.int64(ix)
    iy = np.int64(iy)
    ux = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
    uy = fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0)
    a = _gdot(ix, iy, fx, fy, seed)
    b = _gdot(ix + 1, iy, fx - 1.0, fy, seed)
    c = _gdot(ix, iy + 1, fx, fy - 1.0, seed)
    d = _gdot(ix + 1, iy + 1, fx - 1.0, fy - 1.0, seed)
    return a + ux * (b - a) + uy * (c - a) + ux * uy * (a - b - c + d)


@njit(cache=True)
def fbm(x, y, wl, octaves, seed):
    v = 0.0
    amp = 0.5
    f = 1.0 / wl
    for o in range(octaves):
        v += noise(x * f + 17.3 * o, y * f - 9.1 * o, seed + o) * amp
        amp *= 0.5
        f *= 2.03
    return v * 1.6


@njit(cache=True)
def ridged(x, y, wl, octaves, seed):
    """Ridged multifractal, 0..1: sharp crests, the rest falling away."""
    v = 0.0
    amp = 0.5
    f = 1.0 / wl
    w = 1.0
    tot = 0.0
    for o in range(octaves):
        r = 1.0 - abs(noise(x * f + 5.7 * o, y * f + 3.3 * o, seed + 100 + o)) * 1.45
        r = max(r, 0.0)
        r = r * r * w
        w = min(max(r * 1.5, 0.0), 1.0)
        v += r * amp
        tot += amp
        amp *= 0.5
        f *= 2.1
    return v / tot


def world_coords(n):
    # sample i sits at -WORLD/2 + i * WORLD/n (the game's finest patch
    # vertices land exactly on the samples)
    c = np.arange(n) / n * WORLD - WORLD / 2
    return np.meshgrid(c, c)   # x, z (z grows south: north is -z)


@njit(cache=True)
def field_fbm(X, Z, wl, octaves, seed):
    out = np.empty(X.shape)
    for i in range(X.shape[0]):
        for j in range(X.shape[1]):
            out[i, j] = fbm(X[i, j], Z[i, j], wl, octaves, seed)
    return out


@njit(cache=True)
def grid_fbm(xs, zs, wl, octaves, seed):
    """fbm over the grid xs (columns) x zs (rows), without coordinate arrays."""
    out = np.empty((zs.size, xs.size), np.float32)
    for i in range(zs.size):
        for j in range(xs.size):
            out[i, j] = fbm(xs[j], zs[i], wl, octaves, seed)
    return out


@njit(cache=True)
def grid_ridged(xs, zs, wl, octaves, seed):
    out = np.empty((zs.size, xs.size), np.float32)
    for i in range(zs.size):
        for j in range(xs.size):
            out[i, j] = ridged(xs[j], zs[i], wl, octaves, seed)
    return out


@njit(cache=True)
def field_ridged(X, Z, wl, octaves, seed):
    out = np.empty(X.shape)
    for i in range(X.shape[0]):
        for j in range(X.shape[1]):
            out[i, j] = ridged(X[i, j], Z[i, j], wl, octaves, seed)
    return out


# --- layout ------------------------------------------------------------------
# Every landmass is an elevation field, positive on land: the world's land is
# the highest of them. Distances are normalised so the coast sits at d = 1,
# wobbled by noise so no coast is a circle.

X, Z = world_coords(M)
CELL = WORLD / M
warp = field_fbm(X, Z, 2000.0, 4, SEED + 1)
warp2 = field_fbm(X, Z, 500.0, 3, SEED + 2)
H = np.full((M, M), -1e9)
owner = np.zeros((M, M), np.int32)
landmasses = []


def add(field, kind, cx, cz, radius):
    global H
    k = len(landmasses) + 1
    landmasses.append({"kind": kind, "center": [round(cx, 1), round(cz, 1)], "radius": round(radius, 1)})
    better = field > H
    owner[better] = k
    H = np.where(better, field, H)


def island(kind, cx, cz, r, profile, wob, elong, seed, reach=2.2):
    """A landmass computed in a window around it: d is its distance from the
    centre in coast radii, stretched by elong along a random axis and wobbled
    by noise at its own scale (so small islands aren't circles either)."""
    global H
    ext = r * reach * math.sqrt(elong)
    j0 = max(int((cx - ext + WORLD / 2) / CELL), 0); j1 = min(int((cx + ext + WORLD / 2) / CELL) + 1, M)
    i0 = max(int((cz - ext + WORLD / 2) / CELL), 0); i1 = min(int((cz + ext + WORLD / 2) / CELL) + 1, M)
    Xw, Zw = X[i0:i1, j0:j1], Z[i0:i1, j0:j1]
    th = rng.uniform(0, math.pi)
    dx, dz = Xw - cx, Zw - cz
    u = (dx * math.cos(th) + dz * math.sin(th)) / math.sqrt(elong)
    v = (-dx * math.sin(th) + dz * math.cos(th)) * math.sqrt(elong)
    d = np.hypot(u, v) / r + wob * field_fbm(Xw, Zw, max(r * 0.9, 30.0), 4, seed) \
        + 0.4 * wob * field_fbm(Xw, Zw, max(r * 0.3, 15.0), 3, seed + 1)
    field = profile(d, Xw, Zw)
    k = len(landmasses) + 1
    landmasses.append({"kind": kind, "center": [round(cx, 1), round(cz, 1)], "radius": round(r * math.sqrt(elong), 1)})
    sub = H[i0:i1, j0:j1]
    better = field > sub
    owner[i0:i1, j0:j1][better] = k
    H[i0:i1, j0:j1] = np.where(better, field, sub)


def ndist(cx, cz, r, wobble=0.25, fine=0.06):
    return np.hypot(X - cx, Z - cz) / r + wobble * warp + fine * warp2


def free(cx, cz, r, pad=150.0):
    if abs(cx) + r > WORLD / 2 - 350 or abs(cz) + r > WORLD / 2 - 350:
        return False
    for lm in landmasses:
        if math.hypot(cx - lm["center"][0], cz - lm["center"][1]) < r + lm["radius"] + pad:
            return False
    return True


# the main island and its range
# The world's layout: the main island in the north-west, the archipelago in a
# broad band east of it, the peripheral island far off to the north-east, the
# southern group on a wide bank south of the gap between them, and the
# volcanic chain to the south-east, its cones growing toward the east.
mc = np.array([-4300.0, -3900.0]) + rng.uniform(-250, 250, 2)
MR = rng.uniform(5000, 5400)
edge = np.minimum(WORLD / 2 - np.abs(X), WORLD / 2 - np.abs(Z))
d = ndist(mc[0], mc[1], MR, 0.22) + 0.12 * field_fbm(X, Z, 1400.0, 3, SEED + 14) \
    + np.clip((1200.0 - edge) / 600.0, 0, None)   # (the coast turns back short of the world's edge)
low = 80.0 * np.clip(1.0 - d, 0, 1) ** 0.8 * (0.6 + 0.4 * field_fbm(X, Z, 1800.0, 4, SEED + 3) + 0.4)
low = np.where(d < 1.0, low, (1.0 - d) * 60.0)
spine_a = rng.uniform(0, math.pi)
sd = np.array([math.cos(spine_a), math.sin(spine_a)])
sp = np.array([-sd[1], sd[0]])
off = rng.uniform(-0.25, 0.25) * MR       # the range sits off-centre: a long slope down to one coast
rx = X - mc[0] - sp[0] * off
rz = Z - mc[1] - sp[1] * off
t = (rx * sd[0] + rz * sd[1]) / MR
bphase = rng.uniform(0, 6.3)
bend = 0.22 * MR * np.sin(t * 2.4 + bphase)
dist = np.abs(rx * sp[0] + rz * sp[1] - bend)
along = np.clip(1.0 - np.abs(t) / 0.85, 0, 1) ** 0.6
rmask = np.exp(-(dist / (0.30 * MR)) ** 2) * along * np.clip((1.0 - d) / 0.35, 0, 1)
peaks = 0.55 + 0.45 * field_fbm(X, Z, 3200.0, 2, SEED + 4)
rid = field_ridged(X, Z, 2300.0, 5, SEED + 5)
mount = rmask ** 1.25 * (520.0 + 380.0 * peaks) * (0.45 + 0.75 * rid)
main = low + mount
# the main valley: along the range on its wide side, then out to the coast,
# its floor falling all the way, so one big catchment drains through it
from scipy.spatial import cKDTree
side = -1.0 if off > 0 else 1.0
vt = np.concatenate([np.linspace(-0.7, 0.3, 60), np.linspace(0.3, 0.55, 30)[1:]])
vo = np.concatenate([np.full(60, 0.36), np.linspace(0.36, 1.35, 30)[1:]]) * MR * side - off * 0
vw = mc + sp * off + np.outer(vt * MR, sd) + np.outer(vo + 0.22 * MR * np.sin(vt * 2.4 + bphase), sp)
vs = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(vw, axis=0), axis=1))])
vdist, vi = cKDTree(vw).query(np.stack([X.ravel(), Z.ravel()], 1))
vdist = vdist.reshape(M, M); vi = vi.reshape(M, M)
VW = 1400.0
floor = np.maximum(180.0 * (1.0 - vs[vi] / vs[-1]) ** 1.2, 1.0) + 30.0 * (vdist / VW) ** 2
g = np.exp(-(vdist / (1.4 * VW)) ** 2)
main = main * (1 - g) + g * np.minimum(main, floor)
add(np.where(d < 1.0, main, low), "main_island", mc[0], mc[1], MR)

# the peripheral island, across the sea
pc = np.array([7900.0, -7100.0]) + rng.uniform(-300, 300, 2)
PR = rng.uniform(750, 900)
island("peripheral_island", pc[0], pc[1], PR,
       lambda d, Xw, Zw: np.where(d < 1.0, 160.0 * np.clip(1.0 - d, 0, 1) ** 1.2 * (0.5 + 0.7 * field_ridged(Xw, Zw, 600.0, 4, SEED + 6))
                                  + 25.0 * (1.0 - d), (1.0 - d) * 50.0),
       0.32, rng.uniform(1.2, 1.8), SEED + 20)

# the volcanic chain: cones in a line, steep, each with a crater
v0 = np.array([1700.0, 4300.0]) + rng.uniform(-200, 200, 2)
v1 = np.array([8300.0, 2300.0]) + rng.uniform(-200, 200, 2)
ncones = int(rng.integers(7, 9))
cones = []
for i in range(ncones):
    f = i / (ncones - 1)
    p = v0 + (v1 - v0) * f + np.array([-(v1 - v0)[1], (v1 - v0)[0]]) / np.linalg.norm(v1 - v0) * rng.uniform(-150, 150)
    cones.append((p[0], p[1], (170.0 + 230.0 * f) * rng.uniform(0.85, 1.1)))
volcano_centres = []
for ci, (cx, cz, r) in enumerate(cones):
    hv = (150.0 + 260.0 * ci / (len(cones) - 1)) * rng.uniform(0.85, 1.1)
    cr = rng.uniform(0.1, 0.2)
    island("volcano", cx, cz, r,
           lambda d, Xw, Zw, hv=hv, cr=cr: np.where(d < 1.0, hv * np.clip(1.0 - d, 0, 1) ** 1.5 - 0.35 * hv * np.exp(-(d / cr) ** 2),
                                                 (1.0 - d) * 300.0),
           0.12, rng.uniform(1.0, 1.35), SEED + 30 + ci * 3)
    volcano_centres.append((cx, cz, r))

# the archipelago: many small islands along an arc, on a shallow bank
a0 = np.array([2400.0, -3300.0]) + rng.uniform(-200, 200, 2)
a1 = np.array([8600.0, -2300.0]) + rng.uniform(-200, 200, 2)
arc_mid = 0.5 * (a0 + a1) + np.array([0.0, -500.0]) + rng.uniform(-200, 200, 2)
arc_pts = []
for s in np.linspace(0, 1, 40):
    arc_pts.append((1 - s) ** 2 * a0 + 2 * (1 - s) * s * arc_mid + s * s * a1)
arc_pts = np.array(arc_pts)
islets = 0
islet_ids = []
for _ in range(8000):
    if islets >= 150:
        break
    s = rng.integers(0, len(arc_pts))
    c = arc_pts[s] + rng.normal(0, 1, 2) * np.array([600.0, 1100.0])
    r = float(np.clip(rng.lognormal(math.log(105), 0.85), 25, 650))
    if not free(c[0], c[1], r, 70):
        continue
    # low and smooth: a beach rising to a broad, gently domed top
    hi = min(2.5 + r * rng.uniform(0.025, 0.08), 32.0)
    island("islet", c[0], c[1], r,
           lambda d, Xw, Zw, hi=hi: np.where(d < 1.0, hi * (0.25 + 0.75 * np.clip((1.0 - d) / 0.55, 0, 1) ** 2 * (3 - 2 * np.clip((1.0 - d) / 0.55, 0, 1)))
                                             * np.clip((1.0 - d) / 0.08, 0, 1), (1.0 - d) * 8.0),
           0.45, rng.uniform(1.0, 1.7), SEED + 100 + islets * 3)
    islet_ids.append(len(landmasses))
    islets += 1

# the southern group
south = []
gc = np.array([-400.0, 3000.0]) + rng.uniform(-250, 250, 2)
for _ in range(600):
    if len(south) >= 8:
        break
    c = gc + rng.normal(0, 1000, 2)
    r = rng.uniform(120, 420)
    if not free(c[0], c[1], r, 120):
        continue
    hi = rng.uniform(20, 120)
    island("southern_island", c[0], c[1], r,
           lambda d, Xw, Zw, hi=hi: np.where(d < 1.0, hi * np.clip(1.0 - d, 0, 1) ** 1.1
                                             * (0.6 + 0.6 * field_ridged(Xw, Zw, 400.0, 4, SEED + 13)), (1.0 - d) * 30.0),
           0.35, rng.uniform(1.0, 1.9), SEED + 400 + len(south) * 3)
    south.append(c)
log("layout:", len(landmasses), "landmasses,", islets, "islets,", len(cones), "cones")

# --- seafloor ----------------------------------------------------------------
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


# --- erosion at 10 m: stream power ------------------------------------------------

@njit(cache=True)
def flood_route(h, land, eps):
    """Priority flood from the coast (Barnes 2014): receivers, and an order
    with receivers before donors; depressions filled just enough to drain."""
    n = h.shape[0]
    recv = -np.ones((n, n, 2), np.int64)
    seen = np.zeros((n, n), np.bool_)
    order = np.empty((n * n, 2), np.int64)
    cnt = 0
    hk = np.empty(n * n + 8, np.float64)
    hy = np.empty(n * n + 8, np.int64)
    hx = np.empty(n * n + 8, np.int64)
    size = 0
    for y in range(1, n - 1):
        for x in range(1, n - 1):
            if not land[y, x]:
                continue
            for k in range(8):
                if not land[y + NB[k, 0], x + NB[k, 1]]:
                    recv[y, x, 0] = y + NB[k, 0]
                    recv[y, x, 1] = x + NB[k, 1]
                    seen[y, x] = True
                    i = size
                    size += 1
                    hk[i] = h[y, x]; hy[i] = y; hx[i] = x
                    while i > 0:
                        p = (i - 1) // 2
                        if hk[p] <= hk[i]:
                            break
                        hk[p], hk[i] = hk[i], hk[p]
                        hy[p], hy[i] = hy[i], hy[p]
                        hx[p], hx[i] = hx[i], hx[p]
                        i = p
                    break
    while size > 0:
        y = hy[0]; x = hx[0]
        size -= 1
        hk[0] = hk[size]; hy[0] = hy[size]; hx[0] = hx[size]
        i = 0
        while True:
            l = 2 * i + 1; r = l + 1; s = i
            if l < size and hk[l] < hk[s]: s = l
            if r < size and hk[r] < hk[s]: s = r
            if s == i: break
            hk[s], hk[i] = hk[i], hk[s]
            hy[s], hy[i] = hy[i], hy[s]
            hx[s], hx[i] = hx[i], hx[s]
            i = s
        order[cnt, 0] = y; order[cnt, 1] = x
        cnt += 1
        if y < 1 or x < 1 or y > n - 2 or x > n - 2:
            continue
        for k in range(8):
            yy = y + NB[k, 0]; xx = x + NB[k, 1]
            if not land[yy, xx] or seen[yy, xx]:
                continue
            seen[yy, xx] = True
            if h[yy, xx] < h[y, x] + eps:
                h[yy, xx] = h[y, x] + eps
            recv[yy, xx, 0] = y; recv[yy, xx, 1] = x
            i = size
            size += 1
            hk[i] = h[yy, xx]; hy[i] = yy; hx[i] = xx
            while i > 0:
                p = (i - 1) // 2
                if hk[p] <= hk[i]:
                    break
                hk[p], hk[i] = hk[i], hk[p]
                hy[p], hy[i] = hy[i], hy[p]
                hx[p], hx[i] = hx[i], hx[p]
                i = p
    return recv, order[:cnt]


@njit(cache=True)
def steepest(h, land, order, recv, stochastic, seed):
    """Point each cell at a lower neighbour: the steepest, or (stochastic) one
    picked weighted by slope squared, so channels don't line up with the grid."""
    np.random.seed(seed)
    n = h.shape[0]
    w = np.zeros(8)
    for c in range(order.shape[0]):
        y = order[c, 0]; x = order[c, 1]
        if y < 1 or x < 1 or y > n - 2 or x > n - 2:
            continue
        best = 0.0
        tot = 0.0
        for k in range(8):
            yy = y + NB[k, 0]; xx = x + NB[k, 1]
            hh = h[yy, xx] if land[yy, xx] else -1.0
            s = (h[y, x] - hh) / ND[k]
            w[k] = s * s if s > 0.0 else 0.0
            tot += w[k]
            if s > best and not stochastic:
                best = s
                recv[y, x, 0] = yy; recv[y, x, 1] = xx
        if stochastic and tot > 0.0:
            r = np.random.random() * tot
            for k in range(8):
                r -= w[k]
                if r <= 0.0 and w[k] > 0.0:
                    recv[y, x, 0] = y + NB[k, 0]; recv[y, x, 1] = x + NB[k, 1]
                    break
    return recv


@njit(cache=True)
def accumulate(order, recv, land, cell_area):
    n = land.shape[0]
    a = np.zeros((n, n))
    for c in range(order.shape[0]):
        a[order[c, 0], order[c, 1]] = cell_area
    for c in range(order.shape[0] - 1, -1, -1):
        y = order[c, 0]; x = order[c, 1]
        ry = recv[y, x, 0]; rx = recv[y, x, 1]
        if ry >= 0 and land[ry, rx]:
            a[ry, rx] += a[y, x]
    return a


@njit(cache=True)
def stream_power(h, land, order, recv, area, K, dt, res):
    """One implicit step of dh/dt = -K A^0.5 S (Braun & Willett 2013)."""
    for c in range(order.shape[0]):
        y = order[c, 0]; x = order[c, 1]
        ry = recv[y, x, 0]; rx = recv[y, x, 1]
        hr = h[ry, rx] if land[ry, rx] else 0.0
        d = res * (1.4142135 if (ry != y and rx != x) else 1.0)
        f = K * dt * math.sqrt(area[y, x]) / d
        h[y, x] = (h[y, x] + f * hr) / (1.0 + f)
        if h[y, x] < hr:
            h[y, x] = hr + 1e-3
    return h


@njit(cache=True)
def talus(h, land, res, slope_max, iters):
    """Wherever ground is steeper than the angle of repose to a neighbour,
    some of the excess slides down to it: no needles, no knife edges."""
    n = h.shape[0]
    for _ in range(iters):
        for y in range(1, n - 1):
            for x in range(1, n - 1):
                if not land[y, x]:
                    continue
                for k in range(8):
                    yy = y + NB[k, 0]; xx = x + NB[k, 1]
                    if not land[yy, xx]:
                        continue
                    lim = slope_max * res * ND[k]
                    dd = h[y, x] - h[yy, xx]
                    if dd > lim:
                        m = 0.25 * (dd - lim)
                        h[y, x] -= m
                        h[yy, xx] += m
    return h


def diffuse(h, land, kappa, steps):
    for _ in range(steps):
        h = np.where(land, h + kappa * ndimage.laplace(h), h)
    return h


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


# --- erosion at 5 m: droplets -------------------------------------------------------

@njit(cache=True)
def droplets(h, count, seed, cell):
    """Hydraulic erosion by water droplets (after Hans Beyer's and Sebastian
    Lague's): each runs downhill picking up sediment where it speeds up and
    dropping it where it slows, so gullies cut into slopes and their sediment
    settles into flat valley floors and fans."""
    np.random.seed(seed)
    n = h.shape[0]
    R = 2
    bw = np.zeros((2 * R + 1, 2 * R + 1))
    tot = 0.0
    for dy in range(-R, R + 1):
        for dx in range(-R, R + 1):
            ww = max(0.0, R - math.sqrt(dx * dx + dy * dy))
            bw[dy + R, dx + R] = ww
            tot += ww
    bw /= tot
    inertia, capf, mincap, dep, ero, evap, grav = 0.08, 5.0, 0.02, 0.25, 0.35, 0.015, 9.0
    done = 0
    tries = 0
    while done < count and tries < count * 20:
        tries += 1
        x = np.random.random() * (n - 3) + 1
        y = np.random.random() * (n - 3) + 1
        if h[int(y), int(x)] < 2.0:
            continue
        done += 1
        dx = 0.0; dy = 0.0; sp = 1.0; water = 1.0; sed = 0.0
        for step in range(80):
            ix = int(x); iy = int(y)
            fx = x - ix; fy = y - iy
            h00 = h[iy, ix]; h10 = h[iy, ix + 1]; h01 = h[iy + 1, ix]; h11 = h[iy + 1, ix + 1]
            gx = (h10 - h00) * (1 - fy) + (h11 - h01) * fy
            gy = (h01 - h00) * (1 - fx) + (h11 - h10) * fx
            hh = h00 * (1 - fx) * (1 - fy) + h10 * fx * (1 - fy) + h01 * (1 - fx) * fy + h11 * fx * fy
            dx = dx * inertia - gx * (1 - inertia)
            dy = dy * inertia - gy * (1 - inertia)
            l = math.sqrt(dx * dx + dy * dy)
            if l < 1e-9:
                break
            dx /= l; dy /= l
            x += dx; y += dy
            if x < 2 or y < 2 or x > n - 3 or y > n - 3:
                break
            jx = int(x); jy = int(y)
            gx2 = x - jx; gy2 = y - jy
            nh = h[jy, jx] * (1 - gx2) * (1 - gy2) + h[jy, jx + 1] * gx2 * (1 - gy2) \
                + h[jy + 1, jx] * (1 - gx2) * gy2 + h[jy + 1, jx + 1] * gx2 * gy2
            dh = nh - hh
            if nh < 0.0:   # reached the sea: it drops what it carries there
                break
            cap = max(-dh, mincap) * sp * water * capf
            if sed > cap or dh > 0:
                amt = min(dh, sed) if dh > 0 else (sed - cap) * dep
                sed -= amt
                h[iy, ix] += amt * (1 - fx) * (1 - fy)
                h[iy, ix + 1] += amt * fx * (1 - fy)
                h[iy + 1, ix] += amt * (1 - fx) * fy
                h[iy + 1, ix + 1] += amt * fx * fy
            else:
                amt = min((cap - sed) * ero, -dh)
                for by in range(-R, R + 1):
                    for bx in range(-R, R + 1):
                        cy = iy + by; cx = ix + bx
                        if cy < 1 or cx < 1 or cy > n - 2 or cx > n - 2:
                            continue
                        e = amt * bw[by + R, bx + R]
                        if h[cy, cx] - e < 0.3:
                            e = max(h[cy, cx] - 0.3, 0.0)
                        h[cy, cx] -= e
                        sed += e
            sp = math.sqrt(max(sp * sp + dh * -grav / cell * 5.0, 0.0))
            water *= 1 - evap
    return h


def resize(a, n):
    return ndimage.zoom(a, n / a.shape[0], order=3, mode="nearest")


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

# --- 2.5 m: fine detail and talus -----------------------------------------------------
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
log("fine detail")


# --- rivers ------------------------------------------------------------------------------
# Traced on the 10 m grid from the eroded terrain's drainage: the biggest
# catchment on the main island drains through one mouth; its channels above a
# threshold area become the river system (a trunk and its tributaries, each
# carried on up its valley toward the ridge it rises under; short stubs are
# pruned so the system reads as one clean tree). Their water surfaces are fit
# to the final ground, stepping down in pools and waterfalls where the stream
# runs steep, and carved into it together.

hc = hf.reshape(M, N // M, M, N // M).mean(axis=(1, 3))
land_c = hc > 0.0
hfill = hc.copy()
recv, order = flood_route(hfill, land_c, 1e-3)
recv = steepest(hfill, land_c, order, recv, False, 0)
area = accumulate(order, recv, land_c, CELL * CELL)
main_id = 1
best = None
for y, x in zip(*np.nonzero(land_c & (owner == main_id))):
    ry, rx = recv[y, x]
    if ry >= 0 and not land_c[ry, rx] and (best is None or area[y, x] > area[best]):
        best = (y, x)
mouth = best
inside = np.zeros((M, M), bool)
inside[mouth] = True
for c in range(order.shape[0]):
    y, x = order[c]
    ry, rx = recv[y, x]
    if ry >= 0 and land_c[ry, rx] and inside[ry, rx]:
        inside[y, x] = True
a_mouth = area[mouth]


# The river system as a hierarchy, like a real drainage tree: the trunk up
# from the mouth, its biggest side branches, and a couple of branches off
# each of those; every stream traced up its own valley (by the biggest donor)
# to where it starts.
donors_of = {}
for c in range(order.shape[0]):
    y, x = order[c]
    ry, rx = recv[y, x]
    if inside[y, x] and ry >= 0 and land_c[ry, rx] and inside[ry, rx]:
        donors_of.setdefault((ry, rx), []).append((y, x))
A_HEAD = 4.0e4      # m^2 draining in: where a stream starts


def trace_up(c):
    path = [c]
    while True:
        ds = donors_of.get(path[-1], [])
        if not ds:
            break
        d = max(ds, key=lambda q: area[q])
        if area[d] < A_HEAD:
            break
        path.append(d)
    return path


def branches(path, a_min, count, spacing):
    """The biggest side streams joining a stream (path: downstream order),
    their junctions at least spacing cells apart."""
    on = set(path)
    cand = []
    for i, c in enumerate(path[:-1]):
        for d in donors_of.get(c, []):
            if d not in on and area[d] >= a_min:
                cand.append((area[d], i, d))
    cand.sort(reverse=True)
    out = []
    for a_, i, d in cand:
        if len(out) >= count:
            break
        if all(abs(i - j) >= spacing for _, j, _ in out):
            out.append((a_, i, d))
    return out


trunk = trace_up(mouth)[::-1]
traces = [(trunk + [tuple(recv[mouth])], -1)]   # (one step into the sea)
for a2, i2, d2 in branches(trunk, 2.0e5, 8, 40):
    t2 = trace_up(d2)[::-1]
    if len(t2) * CELL < 500.0:
        continue
    traces.append((t2 + [trunk[i2]], 0))
    j2 = len(traces) - 1
    for a3, i3, d3 in branches(t2, 6.0e4, 2, 30):
        t3 = trace_up(d3)[::-1]
        if len(t3) * CELL >= 400.0:
            traces.append((t3 + [t2[i3]], j2))
log("catchment %.1f km2, %d streams" % (a_mouth / 1e6, len(traces)))


def bilinear(a, wx, wz):
    n = a.shape[0]
    gx = np.clip((wx + WORLD / 2) / WORLD * n, 0, n - 1.001)
    gz = np.clip((wz + WORLD / 2) / WORLD * n, 0, n - 1.001)
    ix = gx.astype(int); iz = gz.astype(int)
    fx = gx - ix; fz = gz - iz
    return (a[iz, ix] * (1 - fx) * (1 - fz) + a[iz, ix + 1] * fx * (1 - fz)
            + a[iz + 1, ix] * (1 - fx) * fz + a[iz + 1, ix + 1] * fx * fz)


def downhill_fit(v):
    """The non-increasing sequence closest to v (pool adjacent violators),
    smoothed over ~200 m so its pools and jumps become one continuous run of
    gentle reaches and rapids (no staircase; the carving fits the ground to
    it), still never rising."""
    sums, counts = [], []
    for x in v:
        sums.append(x); counts.append(1)
        while len(sums) > 1 and sums[-1] / counts[-1] > sums[-2] / counts[-2]:
            s = sums.pop(); c = counts.pop()
            sums[-1] += s; counts[-1] += c
    out = np.concatenate([[s / c] * c for s, c in zip(sums, counts)])
    sm = ndimage.gaussian_filter1d(out, 12.0, mode="nearest")
    return np.minimum.accumulate(sm)


rivers = []
for cells, joins in traces:
    pts = np.array([(x * CELL - WORLD / 2, y * CELL - WORLD / 2) for y, x in cells])
    ar = np.array([area[c] if 0 <= c[0] < M and land_c[c] else a_mouth for c in cells], float)
    ar = np.maximum.accumulate(ar)
    for _ in range(10):   # the cell-to-cell zigzag averaged out, ends fixed
        pts[1:-1] = 0.25 * pts[:-2] + 0.5 * pts[1:-1] + 0.25 * pts[2:]
    # resample every 6 m
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    ss = np.arange(0, s[-1], 6.0).tolist() + [s[-1]]
    pts = np.stack([np.interp(ss, s, pts[:, 0]), np.interp(ss, s, pts[:, 1])], 1)
    ar = np.interp(ss, s, ar)
    # and smoothed over about its own width, so a big river carries no jogs
    # of the grid it was traced on (it would kink where its tributaries join);
    # the ends stay put
    hw_ = 4.5 + 60.0 * np.sqrt(np.clip(ar / a_mouth, 0, 1))
    for sig in (2.0, 4.0, 7.0):
        sm = ndimage.gaussian_filter1d(pts, sig, axis=0, mode="nearest")
        wgt = np.clip((hw_ / 6.0 - sig * 0.6) / (sig * 0.6), 0, 1)[:, None]
        wgt *= np.clip(np.minimum(np.arange(len(pts)), np.arange(len(pts))[::-1]) / 12.0, 0, 1)[:, None]
        pts = pts + (sm - pts) * wgt
    rivers.append({"pts": pts, "area": ar, "joins": int(joins), "s": np.array(ss)})

# widths for game scale: 9 m across at the heads, ~130 m at the mouth
def half_width(area_):
    return 4.5 + 60.0 * np.sqrt(np.clip(area_ / a_mouth, 0, 1))


# gentle meanders where the valley floor is flat (not at the ends, which stay
# put for the joins)
for rv in rivers:
    pts, s = rv["pts"], rv["s"]
    if s[-1] < 600:
        continue
    hw = half_width(rv["area"])
    tan = np.gradient(pts, axis=0)
    tan /= np.maximum(np.linalg.norm(tan, axis=1, keepdims=True), 1e-9)
    nrm = np.stack([-tan[:, 1], tan[:, 0]], 1)
    g = bilinear(hf, pts[:, 0], pts[:, 1])
    slope = np.abs(np.gradient(ndimage.uniform_filter1d(g, 25))) / 6.0
    flat = ndimage.gaussian_filter1d(1.0 - np.clip((slope - 0.005) / 0.03, 0, 1), 20)
    lam = 14.0 * 2 * hw * rng.uniform(0.9, 1.2)
    ph = np.cumsum(np.concatenate([[0], np.diff(s) / lam[1:]])) * 2 * math.pi + rng.uniform(0, 6.3)
    taper = np.clip(s / 300.0, 0, 1) * np.clip((s[-1] - s) / 300.0, 0, 1)
    a_t = 0.18 * lam * flat * taper
    # (never more than half the radius of the bend it's laid round, or the
    # offset folds over itself into a knot on the inside of the bend)
    sm = ndimage.gaussian_filter1d(pts, 8.0, axis=0, mode="nearest")
    ts = np.gradient(sm, axis=0)
    ts /= np.maximum(np.linalg.norm(ts, axis=1, keepdims=True), 1e-9)
    kappa = np.linalg.norm(np.gradient(ts, axis=0), axis=1) / 6.0
    a_t = np.minimum(a_t, 0.5 / np.maximum(ndimage.maximum_filter1d(kappa, 31), 1e-6))
    pts += nrm * (a_t * np.sin(ph))[:, None] + tan * (0.3 * a_t * np.cos(ph))[:, None]


def mouth_funnel(pts):
    """How far into the trunk's funnel-shaped mouth each point is: 0 up to
    500 m from the sea, 1 at the coast."""
    arc_ = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))])
    return np.clip(1.0 - (arc_[-1] - arc_) / 500.0, 0, 1)


def resample(pts, attrs, step=6.0):
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    ss = np.arange(0, s[-1], step).tolist() + [s[-1]]
    out = np.stack([np.interp(ss, s, pts[:, 0]), np.interp(ss, s, pts[:, 1])], 1)
    return out, [np.interp(ss, s, a) for a in attrs]


# confluences: a tributary keeps its own course only until it first comes
# within reach of its river (the river's floodplain), so it never runs along
# beside it; from there it heads in and meets it as real tributaries do,
# crossing the bank at 30-45 degrees and easing in alongside, the two
# currents running together. The approach is laid out in the main river's
# frame (along its bends): straight in at the crossing angle, then a
# parabola from the bank to the centreline.
def unloop(pts, attrs):
    """Drop the points where a centreline doubles back on itself (progress
    measured along a smoothed copy of it), then round off what's left."""
    sm = ndimage.gaussian_filter1d(pts, 12.0, axis=0, mode="nearest")
    ts = np.gradient(sm, axis=0)
    ts /= np.maximum(np.linalg.norm(ts, axis=1, keepdims=True), 1e-9)
    arc = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(sm, axis=0), axis=1))])
    q = arc + np.sum((pts - sm) * ts, axis=1)
    keep = [0]
    for i in range(1, len(pts) - 1):
        if q[i] > q[keep[-1]] + 1.0:
            keep.append(i)
    keep.append(len(pts) - 1)
    pts = pts[keep].copy()
    for _ in range(3):   # (ends fixed)
        pts[1:-1] = 0.25 * pts[:-2] + 0.5 * pts[1:-1] + 0.25 * pts[2:]
    return pts, [a[keep] for a in attrs]


for rv in rivers:
    if rv["joins"] < 0:
        continue
    main = rivers[rv["joins"]]
    mp = main["pts"]
    m_hw = half_width(main["area"])
    if main["joins"] < 0:
        m_hw = m_hw * (1.0 + 0.6 * mouth_funnel(mp) ** 2)   # (the water as wide as it will be)
    m_arc = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(mp, axis=0), axis=1))])
    pts = rv["pts"]
    hw_t = half_width(rv["area"])

    def on_main(sv, span):
        sv = float(np.clip(sv, 0.0, m_arc[-1]))
        c = np.array([np.interp(sv, m_arc, mp[:, 0]), np.interp(sv, m_arc, mp[:, 1])])
        a = np.array([np.interp(sv - span, m_arc, mp[:, 0]), np.interp(sv - span, m_arc, mp[:, 1])])
        b = np.array([np.interp(sv + span, m_arc, mp[:, 0]), np.interp(sv + span, m_arc, mp[:, 1])])
        t = (b - a) / max(np.linalg.norm(b - a), 1e-9)
        return c, t, np.array([-t[1], t[0]])

    # where it first comes within reach of the main river (its floodplain):
    # its course is kept that far, and no further (no running alongside)
    d2 = ((pts[:, None, :] - mp[None, :, :]) ** 2).sum(-1)
    near = np.argmin(d2, axis=1)
    dist = np.sqrt(d2[np.arange(len(pts)), near])
    reach = m_hw[near] + 3.0 * hw_t + 40.0
    within = np.nonzero(dist < reach)[0]
    c = int(within[0]) if len(within) else len(pts) - 1
    c = int(np.clip(c, 3, len(pts) - 1))
    if c * 6.0 < 400.0:
        rv["stub"] = True   # (all of its valley beside its river: it would be only a stub)
    p0 = pts[c]
    t0 = pts[c] - pts[c - 3]
    t0 /= max(np.linalg.norm(t0), 1e-9)
    hw_m = float(m_hw[near[c]])
    _, tm, _ = on_main(m_arc[near[c]], hw_m)
    s0 = m_arc[near[c]] + float(np.dot(p0 - mp[near[c]], tm))
    c0, tm, n0 = on_main(s0, hw_m)
    side = 1.0 if np.dot(p0 - c0, n0) >= 0.0 else -1.0
    y0 = max(abs(float(np.dot(p0 - c0, n0))), 1.3 * hw_m + 5.0)
    # the angle it meets the bank at: 30-45 degrees, steeper only if its own
    # course is heading back upstream (so it never has to hook round)
    heading = math.degrees(math.acos(float(np.clip(np.dot(t0, tm), -1.0, 1.0))))
    angle = min(max(rng.uniform(30.0, 45.0), heading - 70.0), 85.0)
    slope = math.tan(math.radians(angle))
    xc = 2.0 * hw_m / slope              # the parabola into the centreline meets the bank at that slope
    x_line = (y0 - hw_m) / slope         # and a straight run from where it leaves its course
    s_e = min(s0 + xc + x_line, m_arc[-1] - 1.0)
    span = xc + x_line
    approach = []
    for x in np.linspace(span, 0.0, max(int(span / 3.0), 8))[1:]:
        y = hw_m * (x / xc) ** 2 if x <= xc else hw_m + slope * (x - xc)
        cc, _, nn = on_main(s_e - x, hw_m)
        approach.append(cc + nn * side * y)
    pts = np.concatenate([pts[:c + 1], np.array(approach)])
    ar = np.concatenate([rv["area"][:c + 1], np.full(len(approach), rv["area"][c])])
    # (the corner where its course turns onto the approach is rounded off below)
    rv["pts"], (rv["area"],) = resample(pts, [ar])
    rv["join_xy"] = on_main(s_e, hw_m)[0]

def ease_bends(pts, hw, iters=240):
    """Ease every bend tighter than a river that wide can turn (a radius of
    2.5 half widths) by smoothing it locally; the ends stay put."""
    pts = pts.copy()
    for _ in range(iters):
        d0 = pts[1:-1] - pts[:-2]
        d1 = pts[2:] - pts[1:-1]
        turn = np.abs((np.arctan2(d1[:, 1], d1[:, 0]) - np.arctan2(d0[:, 1], d0[:, 0]) + np.pi) % (2 * np.pi) - np.pi)
        ds = 0.5 * (np.linalg.norm(d0, axis=1) + np.linalg.norm(d1, axis=1))
        over = np.clip(turn / np.maximum(ds, 1e-6) * hw[1:-1] / 0.4 - 1.0, 0, 1)
        if over.max() <= 0.0:
            break
        over = ndimage.maximum_filter1d(over, 9)
        pts[1:-1] += (0.5 * (pts[:-2] + pts[2:]) - pts[1:-1]) * (0.5 * over)[:, None]
    return pts


# streams that would be only stubs are left out (and any joining them)
new_id = {}
kept = []
for i, rv in enumerate(rivers):
    if rv.get("stub") or (rv["joins"] >= 0 and rv["joins"] not in new_id):
        continue
    new_id[i] = len(kept)
    kept.append(rv)
for rv in kept:
    if rv["joins"] >= 0:
        rv["joins"] = new_id[rv["joins"]]
log("streams: %d (%d stubs left out)" % (len(kept), len(rivers) - len(kept)))
rivers = kept

# no centreline doubles back on itself (meanders, joins), nor bends tighter
# than it could
for rv in rivers:
    pts, (ar,) = unloop(rv["pts"], [rv["area"]])
    pts, (ar,) = resample(pts, [ar])
    pts = ease_bends(pts, half_width(ar))
    rv["pts"], (rv["area"],) = resample(pts, [ar])
for rv in rivers:
    if rv["joins"] >= 0:
        rv["join_k"] = int(np.argmin(np.linalg.norm(rivers[rv["joins"]]["pts"] - rv["join_xy"], axis=1)))


def with_waterfall(g, base, rid):
    """At most one waterfall on a stream, at its steepest spot (where the
    ground drops the most over 60 m, at least 8 m): the pool below it is
    carried back under the slope to a lip, and the water drops sheer over it.
    Elsewhere the water follows the smooth downhill profile (rapids, not a
    staircase)."""
    lvl = base.copy()
    n = len(g)
    if rid == 0 or n < 40:
        return lvl, 0
    drop = np.full(n, -1.0)
    drop[10:n - 20] = g[10:n - 20] - g[20:n - 10]
    q = int(np.argmax(drop))
    if drop[q] < 8.0:
        return lvl, 0
    k = q + 10
    lvl[q + 1:k + 1] = min(base[k], base[q]) - 0.0
    return np.minimum.accumulate(lvl), 1


# widths, depths and the water surface: the downhill profile closest to the
# ground under the channel, stepped where it runs steep (tributaries end at
# their river's level, the trunk at sea level)
falls = 0
for ri_, rv in enumerate(rivers):
    rv["hw"] = half_width(rv["area"])   # (never narrower than the 2.5 m grid can carve cleanly)
    if rv["joins"] < 0:
        # the trunk opens out into the sea over its last 500 m, a funnel-shaped mouth
        x = mouth_funnel(rv["pts"])
        rv["hw"] = rv["hw"] * (1.0 + 0.6 * x * x)
        rv["funnel"] = x
    rv["depth"] = 1.6 + 5.4 * np.sqrt(np.clip(rv["area"] / a_mouth, 0, 1))   # (deep enough to read as a river)
    if "funnel" in rv:
        rv["depth"] = rv["depth"] * (1.0 - 0.55 * rv.pop("funnel") ** 2)   # shoaling toward the sea
    g = bilinear(hf, rv["pts"][:, 0], rv["pts"][:, 1])
    g = ndimage.minimum_filter1d(g, 5)
    base = downhill_fit(np.maximum(g - 0.3, 0.0))
    rv["level"], nf = with_waterfall(g, base, ri_)
    rv["smooth"] = base
for rv in rivers:
    if rv["joins"] >= 0:
        main = rivers[rv["joins"]]
        k = rv["join_k"]
        rv["level"] = np.maximum(rv["level"], main["level"][k])
        rv["smooth"] = np.maximum(rv["smooth"], main["smooth"][k])
        # where it crosses its river's floodplain (its approach) it lies no
        # higher than the floodplain (the river's level and a bank's height,
        # rising gently away from it), so it never runs perched above it, and
        # it ends at its river's level; and it comes down to those gently:
        # however much it has to be lowered is spread back up its course,
        # easing off by 1 cm a metre (a 5 m drop over 500 m), rather than
        # falling in a step (a waterfall) where it reaches the floodplain or
        # the confluence. Its natural fall is kept everywhere else.
        mp_ = main["pts"]
        d2_ = ((rv["pts"][:, None, :] - mp_[None, :, :]) ** 2).sum(-1)
        nk = np.argmin(d2_, axis=1)
        dist_ = np.sqrt(d2_[np.arange(len(nk)), nk])
        hw_mn = main["hw"][nk]
        plain = main["level"][nk] + 0.5 + 0.012 * np.maximum(dist_ - 1.3 * hw_mn, 0.0)
        across_plain = dist_ < hw_mn + 3.0 * rv["hw"] + 50.0
        target = np.where(across_plain, np.minimum(rv["level"], plain), rv["level"])
        target[-1] = main["level"][k]
        low = np.maximum(rv["level"] - target, 0.0)
        ds_ = np.linalg.norm(np.diff(rv["pts"], axis=0), axis=1)
        for i in range(len(low) - 2, -1, -1):
            low[i] = max(low[i], low[i + 1] - 0.01 * ds_[i])
        rv["level"] = rv["level"] - low
        rv["smooth"] = np.maximum(rv["smooth"] - low, main["smooth"][k])
        rv["level"][-1] = main["level"][k]
        rv["level"] = np.minimum.accumulate(np.maximum(rv["level"], main["level"][k]))
    else:
        rv["level"][-1] = min(rv["level"][-1], 0.0)
        rv["level"] = np.minimum.accumulate(rv["level"])
        # an estuary: the trunk comes down to the sea gently over its last
        # kilometre and a half (2.2 m per km, 0.25 m at the coast), its valley
        # floor with it, rather than running down a beach
        arc_ = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(rv["pts"], axis=0), axis=1))])
        tide = 0.25 + 0.0022 * (arc_[-1] - arc_)
        rv["level"] = np.minimum(rv["level"], tide)
        rv["smooth"] = np.minimum(rv["smooth"], tide + 0.3)
# each fall made sheer: a point just past the lip already at the pool below
for rv in rivers:
    p, L, Ls = rv["pts"], rv["level"], rv["smooth"]
    keep_p, keep = [p[0]], [[rv["hw"][0], rv["depth"][0], L[0], rv["area"][0], Ls[0]]]
    for k in range(1, len(p)):
        plunge = 0.0
        if L[k - 1] - L[k] > 5.0:
            # the fall leans out a little over 4 m (the 2.5 m grid can carve
            # that cleanly under it), into a plunge pool dug deeper below
            d = p[k] - p[k - 1]
            plunge = min(0.4 * (L[k - 1] - L[k]), 6.0)
            keep_p.append(p[k - 1] + d / max(np.linalg.norm(d), 1e-9) * min(4.0, 0.8 * np.linalg.norm(d)))
            keep.append([rv["hw"][k], rv["depth"][k] + plunge, L[k], rv["area"][k], 0.5 * (Ls[k - 1] + Ls[k])])
            falls += 1
        keep_p.append(p[k])
        keep.append([rv["hw"][k], rv["depth"][k] + plunge * 0.6, L[k], rv["area"][k], Ls[k]])
    a = np.array(keep)
    rv["pts"] = np.array(keep_p)
    rv["hw"], rv["depth"], rv["level"], rv["area"], rv["smooth"] = a[:, 0], a[:, 1], a[:, 2], a[:, 3], a[:, 4]
    # the water thins in over a stream's first 250 m (as the game draws it):
    # the channel deepens in with it
    seg = np.linalg.norm(np.diff(rv["pts"], axis=0), axis=1)
    arc = np.concatenate([[0], np.cumsum(seg)])
    x = np.clip(arc / 250.0, 0, 1)
    rv["depth"] = rv["depth"] * np.maximum(x * x * (3 - 2 * x), 0.05)
log("waterfalls:", falls)


@njit(cache=True)
def _seg_window(ax, az, bx, bz, reach, world, cell, x0, z0, hx, hz):
    i0 = max(int((min(ax, bx) - reach + world / 2) / cell) - x0, 0)
    i1 = min(int((max(ax, bx) + reach + world / 2) / cell) + 1 - x0, hx - 1)
    j0 = max(int((min(az, bz) - reach + world / 2) / cell) - z0, 0)
    j1 = min(int((max(az, bz) + reach + world / 2) / cell) + 1 - z0, hz - 1)
    return i0, i1, j0, j1


@njit(cache=True)
def carve_river(px_, pz_, L, Ls, HW, DP, VR, world, n, x0, z0, T, W, R):
    """One river's ground over a window (T, W, R start at x0, z0): the bed (a
    parabola below the water), banks rising just above it and a floodplain
    easing out into the land. The level, width and depth come from the
    nearby reaches, blended with a falloff that is sharp at the channel (so a
    waterfall stays sheer) and wide far out (so where the nearest reach jumps
    from one arm of a bend to the other the floodplain doesn't step). The bed
    and banks follow the water level (L), steps and all; beyond the banks the
    floodplain eases over to the smooth valley profile (Ls), so a waterfall's
    cliff spans the stream, not the whole valley. The river's ground reaches
    VR half widths out: wide floodplains in the lowlands, a narrow strip
    beside a mountain stream. W is how much of the ground is the river's, R
    the distance in half widths."""
    cell = world / n
    hz, hx = T.shape
    D = np.full((hz, hx), 1e9, np.float32)
    for k in range(px_.size - 1):
        ax = px_[k]; az = pz_[k]; bx = px_[k + 1]; bz = pz_[k + 1]
        i0, i1, j0, j1 = _seg_window(ax, az, bx, bz, 9.0 * max(HW[k], HW[k + 1]), world, cell, x0, z0, hx, hz)
        abx = bx - ax; abz = bz - az
        ll = abx * abx + abz * abz + 1e-9
        for j in range(j0, j1 + 1):
            pz = (j + z0) * cell - world / 2
            for i in range(i0, i1 + 1):
                px = (i + x0) * cell - world / 2
                u = min(max(((px - ax) * abx + (pz - az) * abz) / ll, 0.0), 1.0)
                dx = px - (ax + abx * u); dz = pz - (az + abz * u)
                d = math.sqrt(dx * dx + dz * dz)
                if d < D[j, i]:
                    D[j, i] = d
    SWr = np.zeros((hz, hx), np.float32)
    SL = np.zeros((hz, hx), np.float32)
    SLs = np.zeros((hz, hx), np.float32)
    SH = np.zeros((hz, hx), np.float32)
    SD = np.zeros((hz, hx), np.float32)
    SV = np.zeros((hz, hx), np.float32)
    for k in range(px_.size - 1):
        ax = px_[k]; az = pz_[k]; bx = px_[k + 1]; bz = pz_[k + 1]
        i0, i1, j0, j1 = _seg_window(ax, az, bx, bz, 9.0 * max(HW[k], HW[k + 1]), world, cell, x0, z0, hx, hz)
        abx = bx - ax; abz = bz - az
        ll = abx * abx + abz * abz + 1e-9
        for j in range(j0, j1 + 1):
            pz = (j + z0) * cell - world / 2
            for i in range(i0, i1 + 1):
                dm = D[j, i]
                px = (i + x0) * cell - world / 2
                u = min(max(((px - ax) * abx + (pz - az) * abz) / ll, 0.0), 1.0)
                dx = px - (ax + abx * u); dz = pz - (az + abz * u)
                d = math.sqrt(dx * dx + dz * dz)
                e = (d - dm) / (0.2 * dm + 0.5)
                if e > 9.0:
                    continue
                w = math.exp(-e)
                SWr[j, i] += w
                SL[j, i] += w * (L[k] + (L[k + 1] - L[k]) * u)
                SLs[j, i] += w * (Ls[k] + (Ls[k + 1] - Ls[k]) * u)
                SH[j, i] += w * (HW[k] + (HW[k + 1] - HW[k]) * u)
                SD[j, i] += w * (DP[k] + (DP[k + 1] - DP[k]) * u)
                SV[j, i] += w * (VR[k] + (VR[k + 1] - VR[k]) * u)
    for j in range(hz):
        for i in range(hx):
            sw = SWr[j, i]
            if sw <= 0.0:
                continue
            hw = SH[j, i] / sw
            r = D[j, i] / hw
            vr = SV[j, i] / sw
            if r > vr:
                continue
            lvl = SL[j, i] / sw
            if r > 1.6:
                y = min((r - 1.6) / 1.9, 1.0)
                lvl += (SLs[j, i] / sw - lvl) * y * y * (3.0 - 2.0 * y)
            dep = SD[j, i] / sw
            if r < 1.0:
                tgt = lvl - dep * (1.0 - r * r)
            else:
                # the bank rises steeply out of the water, then the
                # floodplain climbs gently away
                x = min((r - 1.0) / 0.3, 1.0)
                tgt = lvl + min(0.4 + 0.15 * dep, dep * 0.8) * x * (2.0 - x) + max(r - 1.3, 0.0) * hw * 0.012
            x = min(max((r - 1.3) / (vr - 1.3), 0.0), 1.0)
            T[j, i] = tgt
            W[j, i] = 1.0 - x * x * (3.0 - 2.0 * x)
            R[j, i] = r


@njit(cache=True)
def blend_in(T, W, R, x0, z0, trib, SW, ST, WM, RM, CUT, BED):
    """Add one river's ground to the network's: weighted by its claim on the
    ground (W^8), so where two rivers' valleys overlap the stronger takes over
    smoothly; a tributary's channel fades out inside the water of the rivers
    already carved (it ends inside one of them). Each river's own channel is
    kept in CUT, so that it can be cut through the others' banks afterwards
    (a tributary keeps its width right into its river); BED is how much of
    the ground is a river's bed or bank (for the sand and gravel)."""
    hz, hx = T.shape
    for j in range(hz):
        for i in range(hx):
            w = W[j, i]
            if w <= 0.0:
                continue
            jj = j + z0; ii = i + x0
            if trib:   # (only inside the other river's water, so the two channels meet)
                x = min(max((RM[jj, ii] - 0.55) / 0.45, 0.0), 1.0)
                w *= x * x * (3.0 - 2.0 * x)
            if R[j, i] < 1.1:
                CUT[jj, ii] = min(CUT[jj, ii], T[j, i])
            BED[jj, ii] = max(BED[jj, ii], min(max((1.45 - R[j, i]) / 0.15, 0.0), 1.0))
            o = w ** 8
            SW[jj, ii] += o
            ST[jj, ii] += o * T[j, i]
            WM[jj, ii] = max(WM[jj, ii], w)
    for j in range(hz):
        for i in range(hx):
            if W[j, i] > 0.0:
                RM[j + z0, i + x0] = min(RM[j + z0, i + x0], R[j, i])


SW = np.zeros((N, N), np.float32)
ST = np.zeros((N, N), np.float32)
Wt = np.zeros((N, N), np.float32)
RM = np.full((N, N), 1e9, np.float32)
CUT = np.full((N, N), 1e9, np.float32)
BED = np.zeros((N, N), np.float32)
for ri, rv in enumerate(rivers):
    p = rv["pts"]
    reach = 9.0 * rv["hw"].max() + 10.0
    x0 = max(int((p[:, 0].min() - reach + WORLD / 2) / (WORLD / N)), 0)
    x1 = min(int((p[:, 0].max() + reach + WORLD / 2) / (WORLD / N)) + 1, N)
    z0 = max(int((p[:, 1].min() - reach + WORLD / 2) / (WORLD / N)), 0)
    z1 = min(int((p[:, 1].max() + reach + WORLD / 2) / (WORLD / N)) + 1, N)
    Tw = np.zeros((z1 - z0, x1 - x0), np.float32)
    Ww = np.zeros_like(Tw)
    Rw = np.full_like(Tw, 1e9)
    # the floodplain reaches far where the valley floor is flat, little on steep ground
    sl = np.abs(np.gradient(ndimage.uniform_filter1d(rv["smooth"], 15))) / np.maximum(
        np.linalg.norm(np.gradient(p, axis=0), axis=1), 0.5)
    vr = 3.0 + 6.0 * np.clip(1.0 - (sl - 0.02) / 0.06, 0, 1)
    carve_river(p[:, 0].copy(), p[:, 1].copy(), rv["level"], rv["smooth"], rv["hw"], rv["depth"], vr, WORLD, N, x0, z0, Tw, Ww, Rw)
    blend_in(Tw, Ww, Rw, x0, z0, rv["joins"] >= 0, SW, ST, Wt, RM, CUT, BED)
T = np.where(SW > 0, ST / np.maximum(SW, 1e-30), 0.0).astype(np.float32)
T = np.minimum(T, CUT)   # every channel cut through the banks of the others
channel = CUT < 1e8      # (the rivers' beds: sand and gravel, below)
del ST, RM, CUT
# blended in (the land beside the river pulled toward its floodplain, both
# ways), except out at sea
hf = np.where((SW > 0) & ((hf > -1.0) | (T < hf) | channel), hf + (T - hf) * Wt, hf)
del SW, T
log("rivers: %d, %d points" % (len(rivers), sum(len(r["pts"]) for r in rivers)))

# --- masks ---------------------------------------------------------------------------------
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
del channel, BED
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

# --- trees: triangles standing in for them ----------------------------------------------------
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
rec["y"] = np.clip((ty - H_MIN) / (H_MAX - H_MIN) * 65535.0 + 0.5, 0, 65535).astype(np.uint16)
rec["s"] = rng.integers(0, 256, tx.size).astype(np.uint8)
open(ROOT + "trees.bin", "wb").write(zlib.compress(rec.tobytes(), 9))
log("trees:", tx.size)

# --- spawn: a beach on the main island near the river mouth, the boat offshore ----------------
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

# --- write -----------------------------------------------------------------------------------------
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
out = {
    "seed": SEED, "world_size": WORLD, "texels": N, "h_min": H_MIN, "h_max": H_MAX,
    "spawn": [round(float(spot[0]), 2), round(float(spot[1]), 2)],
    "boat": [round(float(boat[0]), 2), round(float(boat[1]), 2)],
    "trees": int(tx.size),
    "landmasses": landmasses,
    "rivers": [{
        "points": [[round(float(p[0]), 2), round(float(l), 3), round(float(p[1]), 2)] for p, l in zip(rv["pts"], rv["level"])],
        "half_width": [round(float(v), 2) for v in rv["hw"]],
        "depth": [round(float(v), 2) for v in rv["depth"]],
        "joins": rv["joins"],
    } for rv in rivers],
}
json.dump(out, open(ROOT + "world.json", "w"), separators=(",", ":"))
log("written: heights %.1f MB, trees %d, max %.0f m, min %.0f m" % (
    (os.path.getsize(ROOT + "height_hi.bin") + os.path.getsize(ROOT + "height_lo.bin")) / 1e6, tx.size, hf.max(), hf.min()))
