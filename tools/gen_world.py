# World generator (not part of the game): python3 tools/gen_world.py [seed]
# Needs numpy, scipy, pillow and numba. About a minute.
#
# Makes a 10 x 10 km test world of islands from a seed and writes it to
# world/ for the game to load:
#   - a main island (~5.5 km) with a mountain range down its spine (peaks
#     600-900 m) and one river system, a peripheral island, a long archipelago
#     of small islands on a shallow sandy bank, a chain of volcanic cones in
#     deep water, and a southern group of islands;
#   - eroded at three scales: stream-power erosion at 10 m (the drainage,
#     ridges and valleys), droplet erosion at 5 m (gullies, with sediment
#     settling into flat valley floors and fans), and a talus pass at 2.5 m;
#   - the rivers traced from the eroded drainage and carved into the final
#     2.5 m heights together with their water level, so the water always lies
#     in its bed: the bed, the banks and a flat floodplain blending out into
#     the valley;
#   - masks for the ground (rock, sand, forest, ambient occlusion) and the
#     stand-in trees (triangles) scattered by the forest mask.
#
# Outputs (world/, which Godot doesn't import):
#   height_hi.bin, height_lo.bin   zlib: the high and low bytes of uint16
#                heights, 4096 x 4096 and every mip down to 1 x 1
#   ground.png   2048 x 2048 RGBA: rock, sand, forest density, ambient occlusion
#   trees.bin    zlib: per tree uint16 x, uint16 z, uint8 height (dm / 2), uint8 spare
#   world.json   sizes, height range, rivers, spawn, landmasses
import json, math, os, sys, time, zlib
import numpy as np
from PIL import Image
from scipy import ndimage
from numba import njit

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "world") + "/"
os.makedirs(ROOT, exist_ok=True)
SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 7
WORLD = 10240.0                 # m; the world is the square +-WORLD/2, origin at its centre
N = 4096                        # final grid: 2.5 m
M = 1024                        # coarse grid: 10 m
MID = 2048                      # droplet grid: 5 m
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
warp = field_fbm(X, Z, 1400.0, 4, SEED + 1)
warp2 = field_fbm(X, Z, 380.0, 3, SEED + 2)
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
ang = rng.uniform(0, 2 * math.pi)
mc = np.array([math.cos(ang), math.sin(ang)]) * rng.uniform(600, 1100)
MR = rng.uniform(2550, 2850)
d = ndist(mc[0], mc[1], MR, 0.28) + 0.12 * field_fbm(X, Z, 700.0, 3, SEED + 14)
low = 70.0 * np.clip(1.0 - d, 0, 1) ** 0.8 * (0.6 + 0.4 * field_fbm(X, Z, 900.0, 4, SEED + 3) + 0.4)
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
peaks = 0.55 + 0.45 * field_fbm(X, Z, 1700.0, 2, SEED + 4)
rid = field_ridged(X, Z, 1300.0, 5, SEED + 5)
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
VW = 480.0
floor = np.maximum(120.0 * (1.0 - vs[vi] / vs[-1]) ** 1.2, 1.0) + 30.0 * (vdist / VW) ** 2
g = np.exp(-(vdist / (1.4 * VW)) ** 2)
main = main * (1 - g) + g * np.minimum(main, floor)
add(np.where(d < 1.0, main, low), "main_island", mc[0], mc[1], MR)

# the peripheral island, across the sea
for _ in range(200):
    a = rng.uniform(0, 2 * math.pi)
    pc = mc + np.array([math.cos(a), math.sin(a)]) * rng.uniform(3600, 4400)
    PR = rng.uniform(650, 800)
    if free(pc[0], pc[1], PR, 600):
        break
island("peripheral_island", pc[0], pc[1], PR,
       lambda d, Xw, Zw: np.where(d < 1.0, 160.0 * np.clip(1.0 - d, 0, 1) ** 1.2 * (0.5 + 0.7 * field_ridged(Xw, Zw, 600.0, 4, SEED + 6))
                                  + 25.0 * (1.0 - d), (1.0 - d) * 50.0),
       0.32, rng.uniform(1.2, 1.8), SEED + 20)

# the volcanic chain: cones in a line, steep, each with a crater
for _ in range(200):
    a = rng.uniform(0, 2 * math.pi)
    vs = mc + np.array([math.cos(a), math.sin(a)]) * rng.uniform(3300, 4200)
    va = a + math.pi / 2 + rng.uniform(-0.5, 0.5)
    vd = np.array([math.cos(va), math.sin(va)])
    ok = True
    cones = []
    p = vs.copy()
    r = rng.uniform(200, 420)
    for i in range(int(rng.integers(6, 8))):
        cones.append((p[0], p[1], r))
        r2 = rng.uniform(170, 420)
        p = p + vd * (r + r2 + rng.uniform(250, 600)) + np.array([-vd[1], vd[0]]) * rng.uniform(-250, 250)
        r = r2
    if all(free(c[0], c[1], c[2], 250) for c in cones):
        break
volcano_centres = []
for ci, (cx, cz, r) in enumerate(cones):
    hv = rng.uniform(150, 440)
    cr = rng.uniform(0.1, 0.2)
    island("volcano", cx, cz, r,
           lambda d, Xw, Zw, hv=hv, cr=cr: np.where(d < 1.0, hv * np.clip(1.0 - d, 0, 1) ** 1.5 - 0.35 * hv * np.exp(-(d / cr) ** 2),
                                                 (1.0 - d) * 300.0),
           0.12, rng.uniform(1.0, 1.35), SEED + 30 + ci * 3)
    volcano_centres.append((cx, cz, r))

# the archipelago: many small islands along an arc, on a shallow bank
for _ in range(200):
    a = rng.uniform(0, 2 * math.pi)
    a0 = mc + np.array([math.cos(a), math.sin(a)]) * (MR + rng.uniform(500, 900))
    a1 = a0 + np.array([math.cos(a + rng.uniform(-1.0, 1.0)), math.sin(a + rng.uniform(-1.0, 1.0))]) * 3600
    if abs(a1[0]) < WORLD / 2 - 600 and abs(a1[1]) < WORLD / 2 - 600 and free(*(0.5 * (a0 + a1)), 300, 300):
        break
arc_mid = 0.5 * (a0 + a1) + np.array([-(a1 - a0)[1], (a1 - a0)[0]]) * rng.uniform(-0.15, 0.15)
arc_pts = []
for s in np.linspace(0, 1, 40):
    arc_pts.append((1 - s) ** 2 * a0 + 2 * (1 - s) * s * arc_mid + s * s * a1)
arc_pts = np.array(arc_pts)
islets = 0
for _ in range(4000):
    if islets >= 90:
        break
    s = rng.integers(0, len(arc_pts))
    c = arc_pts[s] + rng.normal(0, 380, 2)
    r = float(np.clip(rng.lognormal(math.log(70), 0.7), 22, 360))
    if not free(c[0], c[1], r, 30):
        continue
    hi = 3.0 + r * rng.uniform(0.06, 0.3)
    island("islet", c[0], c[1], r,
           lambda d, Xw, Zw, hi=hi: np.where(d < 1.0, hi * np.clip(1.0 - d, 0, 1) ** 0.9, (1.0 - d) * 8.0),
           0.4, rng.uniform(1.0, 2.6), SEED + 100 + islets * 3)
    islets += 1

# the southern group
south = []
for _ in range(400):
    a = rng.uniform(0, 2 * math.pi)
    gc = mc + np.array([math.cos(a), math.sin(a)]) * rng.uniform(3300, 4300)
    if abs(gc[0]) < WORLD / 2 - 900 and abs(gc[1]) < WORLD / 2 - 900 and free(gc[0], gc[1], 700, 300):
        break
for _ in range(600):
    if len(south) >= 8:
        break
    c = gc + rng.normal(0, 650, 2)
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
bank = np.maximum(near_pts(arc_pts, 700.0), near_pts(south, 900.0) if south else 0.0)
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
XM, ZM = world_coords(MID)
land_m = hm > 0.0
slope_m = np.hypot(*np.gradient(hm, WORLD / MID))
# mid-scale detail on the slopes before the droplets run: they cut it into gullies
hm += np.where(land_m, (field_ridged(XM, ZM, 160.0, 3, SEED + 9) - 0.4) * 14.0 * np.clip(slope_m / 0.4, 0, 1)
               * np.clip(hm / 30.0, 0, 1), 0.0)
hm = droplets(hm, 900000, SEED, WORLD / MID)
log("droplets; max %.0f m" % hm.max())

# --- 2.5 m: fine detail and talus -----------------------------------------------------
hf = resize(hm, N)
XF, ZF = world_coords(N)
land_f = hf > 0.0
slope_f = np.hypot(*np.gradient(hf, WORLD / N))
hf += np.where(land_f, field_fbm(XF, ZF, 40.0, 3, SEED + 10) * (0.4 + 2.0 * np.clip(slope_f, 0, 1)) * np.clip(hf / 4.0, 0, 1), 0.0)
hf = talus(hf, land_f, WORLD / N, math.tan(math.radians(42.0)), 6)
log("fine detail")


# --- rivers ------------------------------------------------------------------------------
# Traced on the 10 m grid from the eroded terrain's drainage: the biggest
# catchment on the main island drains through one mouth; its channels above a
# threshold area become the river system (a trunk and a handful of
# tributaries). Their water surfaces are fit to the final ground and carved
# into it together.

hc = resize(hf, M)
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


def network(thr):
    ch = inside & (area >= thr)
    donors = np.zeros((M, M), np.int32)
    for y, x in zip(*np.nonzero(ch)):
        ry, rx = recv[y, x]
        if ry >= 0 and ch[ry, rx]:
            donors[ry, rx] += 1
    return ch, donors, int(((donors == 0) & ch).sum())


lo, hi = 2e4, a_mouth
for _ in range(30):
    mid = math.sqrt(lo * hi)
    if network(mid)[2] > 12:
        lo = mid
    else:
        hi = mid
ch, donors, nheads = network(hi)
log("catchment %.1f km2, %d heads" % (a_mouth / 1e6, nheads))

# trace every head down to the sea or to a river already traced, longest first
def path_len(y, x):
    k = 0
    while ch[y, x] and k < 100000:
        y, x = recv[y, x]
        k += 1
    return k

heads = sorted([(path_len(y, x), y, x) for y, x in zip(*np.nonzero(ch & (donors == 0)))], reverse=True)
river_of = -np.ones((M, M), np.int64)
traces = []
for _, y, x in heads:
    cells = []
    joins = -1
    while True:
        cells.append((y, x))
        if river_of[y, x] >= 0:
            joins = river_of[y, x]
            break
        ry, rx = recv[y, x]
        if ry < 0 or not land_c[ry, rx]:
            cells.append((ry, rx))   # one step into the sea
            break
        y, x = ry, rx
    for c in cells[:-1] if joins >= 0 else cells:
        if 0 <= c[0] < M and 0 <= c[1] < M:
            river_of[c] = len(traces)
    if len(cells) >= 6:
        traces.append((cells, joins))


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
    lightly smoothed, only ever lowered."""
    sums, counts = [], []
    for x in v:
        sums.append(x); counts.append(1)
        while len(sums) > 1 and sums[-1] / counts[-1] > sums[-2] / counts[-2]:
            s = sums.pop(); c = counts.pop()
            sums[-1] += s; counts[-1] += c
    out = np.concatenate([[s / c] * c for s, c in zip(sums, counts)])
    sm = ndimage.uniform_filter1d(out, 9, mode="nearest")
    return np.minimum.accumulate(np.minimum(sm, out + 0.0))


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
    rivers.append({"pts": pts, "area": ar, "joins": int(joins), "s": np.array(ss)})

# gentle meanders where the valley floor is flat (not on the trunk's last
# stretch into the sea, nor at the ends, which stay put for the joins)
for rv in rivers:
    pts, s = rv["pts"], rv["s"]
    if s[-1] < 600:
        continue
    hw = 4.5 + 25.5 * np.sqrt(rv["area"] / a_mouth)
    tan = np.gradient(pts, axis=0)
    tan /= np.maximum(np.linalg.norm(tan, axis=1, keepdims=True), 1e-9)
    nrm = np.stack([-tan[:, 1], tan[:, 0]], 1)
    g = bilinear(hf, pts[:, 0], pts[:, 1])
    slope = np.abs(np.gradient(ndimage.uniform_filter1d(g, 25))) / 6.0
    flat = ndimage.gaussian_filter1d(1.0 - np.clip((slope - 0.005) / 0.03, 0, 1), 20)
    lam = 16.0 * 2 * hw * rng.uniform(0.9, 1.2)
    ph = np.cumsum(np.concatenate([[0], np.diff(s) / lam[1:]])) * 2 * math.pi + rng.uniform(0, 6.3)
    taper = np.clip(s / 300.0, 0, 1) * np.clip((s[-1] - s) / 300.0, 0, 1)
    a_t = 0.22 * lam * flat * taper
    pts += nrm * (a_t * np.sin(ph))[:, None] + tan * (0.3 * a_t * np.cos(ph))[:, None]

# widths, depths and the water surface: the downhill profile closest to the
# ground under the channel (tributaries end at their river's level, the trunk
# at sea level)
for i, rv in enumerate(rivers):
    f = np.sqrt(np.clip(rv["area"] / a_mouth, 0, 1))
    rv["hw"] = 4.5 + 25.5 * f   # (never narrower than the 2.5 m grid can carve cleanly)
    rv["depth"] = 0.8 + 2.7 * f
    g = bilinear(hf, rv["pts"][:, 0], rv["pts"][:, 1])
    g = ndimage.minimum_filter1d(g, 5)
    rv["level"] = downhill_fit(np.maximum(g - 0.3, 0.0))
for i, rv in enumerate(rivers):
    if rv["joins"] >= 0:
        main = rivers[rv["joins"]]
        end = rv["pts"][-1]
        k = int(np.argmin(np.linalg.norm(main["pts"] - end, axis=1)))
        rv["pts"][-1] = main["pts"][k]
        rv["level"] = np.maximum(rv["level"], main["level"][k])
        rv["level"][-1] = main["level"][k]
    else:
        rv["level"][-1] = min(rv["level"][-1], 0.0)
        rv["level"] = np.minimum.accumulate(rv["level"])


@njit(cache=True)
def carve(h, ax, az, bx, bz, la, lb, hwa, hwb, da, db, world, T, W, R, I, rid):
    """Rasterise one channel segment's ground: the bed (a parabola below the
    water), banks rising just above it and a floodplain easing out into the
    land. T holds the target ground at a pixel, W how much of the ground is
    the river's there: within one river the nearest segment decides (R, I:
    its distance and river), where rivers meet the lowest ground wins."""
    n = h.shape[0]
    cell = world / n
    reach = 9.0 * max(hwa, hwb)
    x0 = int(((min(ax, bx) - reach) + world / 2) / cell)
    x1 = int(((max(ax, bx) + reach) + world / 2) / cell) + 1
    z0 = int(((min(az, bz) - reach) + world / 2) / cell)
    z1 = int(((max(az, bz) + reach) + world / 2) / cell) + 1
    abx = bx - ax; abz = bz - az
    ll = abx * abx + abz * abz + 1e-9
    for j in range(max(z0, 0), min(z1, n - 1) + 1):
        pz = j * cell - world / 2
        for i in range(max(x0, 0), min(x1, n - 1) + 1):
            px = i * cell - world / 2
            u = min(max(((px - ax) * abx + (pz - az) * abz) / ll, 0.0), 1.0)
            dx = px - (ax + abx * u); dz = pz - (az + abz * u)
            hw = hwa + (hwb - hwa) * u
            r = math.sqrt(dx * dx + dz * dz) / hw
            if r > 9.0:
                continue
            lvl = la + (lb - la) * u
            dep = da + (db - da) * u
            if r < 1.0:
                tgt = lvl - dep * (1.0 - r * r)
            else:
                # the bank rises steeply out of the water, then the floodplain
                # climbs gently away
                x = min((r - 1.0) / 0.3, 1.0)
                tgt = lvl + (0.4 + 0.15 * dep) * x * (2.0 - x) + max(r - 1.3, 0.0) * hw * 0.012
            x = min(max((r - 1.3) / (9.0 - 1.3), 0.0), 1.0)
            w = 1.0 - x * x * (3.0 - 2.0 * x)
            if w > W[j, i] + 0.02:
                W[j, i] = w
                T[j, i] = tgt
                R[j, i] = r
                I[j, i] = rid
            elif w > W[j, i] - 0.02:
                W[j, i] = max(W[j, i], w)
                if I[j, i] == rid:
                    if r < R[j, i]:
                        T[j, i] = tgt
                        R[j, i] = r
                elif tgt < T[j, i]:
                    T[j, i] = tgt
                    R[j, i] = r
                    I[j, i] = rid


T = np.zeros((N, N))
Wt = np.zeros((N, N))
Rn = np.full((N, N), 1e9)
In = -np.ones((N, N), np.int64)
for ri, rv in enumerate(rivers):
    p, L, hw, dp = rv["pts"], rv["level"], rv["hw"], rv["depth"]
    for k in range(len(p) - 1):
        carve(hf, p[k, 0], p[k, 1], p[k + 1, 0], p[k + 1, 1], L[k], L[k + 1], hw[k], hw[k + 1], dp[k], dp[k + 1], WORLD, T, Wt, Rn, In, ri)
# blended in (the land beside the river pulled toward its floodplain, both
# ways), except out at sea
hf = np.where((Wt > 0) & ((hf > -1.0) | (T < hf)), hf + (T - hf) * Wt, hf)
log("rivers: %d, %d points" % (len(rivers), sum(len(r["pts"]) for r in rivers)))

# --- masks ---------------------------------------------------------------------------------
G = 2048
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
clump = field_fbm(XG, ZG, 650.0, 4, SEED + 11) + 0.35 * field_fbm(XG, ZG, 120.0, 3, SEED + 12)
forest = np.clip((clump + 0.15) / 0.45, 0, 1) * np.clip(1.0 - (slope - 24.0) / 10.0, 0, 1) \
    * np.clip((hg - 4.0) / 6.0, 0, 1) * np.clip(1.0 - (hg - 560.0) / 160.0, 0, 1) \
    * (1.0 - sand) * (1.0 - np.clip((river_r - 0.75) / 0.2, 0, 1))
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
rec = np.zeros(tx.size, dtype=[("x", "<u2"), ("z", "<u2"), ("h", "u1"), ("s", "u1")])
rec["x"] = q(tx); rec["z"] = q(tz); rec["h"] = np.clip(th * 10.0, 0, 255).astype(np.uint8)
rec["s"] = rng.integers(0, 256, tx.size).astype(np.uint8)
open(ROOT + "trees.bin", "wb").write(zlib.compress(rec.tobytes(), 9))
log("trees:", tx.size)

# --- spawn: a beach on the main island near the river mouth, the boat offshore ----------------
mw = np.array([mouth[1] * CELL - WORLD / 2, mouth[0] * CELL - WORLD / 2])
owner_g = owner.repeat(2, 0).repeat(2, 1)
cand = np.argwhere(land_g & (hg > 1.2) & (hg < 6.0) & (slope < 8.0) & (river_r < 0.05) & (sea_d < 60) & (owner_g == main_id))
pos = (cand[:, ::-1] + 0.25) * cellg - WORLD / 2   # (2048 cells are 2 x 2 means of the samples)
dd = np.linalg.norm(pos - mw, axis=1)
okc = (dd > 250) & (dd < 900)
spot = pos[okc][np.argmin(np.abs(dd[okc] - 450))] if okc.any() else pos[np.argmin(dd)]
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
