# Map-making tool (not part of the game): python3 tools/erode_maps.py [heads]
# Needs numpy, scipy, pillow and numba. Reads the painted original from
# world/maps/src/main_island_painted.png, so it can be rerun at will.
#
# Erode the main island's height map (stream-power fluvial erosion with
# hillslope diffusion and a talus limit), keep its painted large-scale shape,
# and derive a realistic, loop-free river network from the eroded terrain's own
# drainage, meandering in the lowlands, with oxbow lakes cut off beside the
# bends. Maps only: writes world/maps/main_island_height.png and
# main_island_rivers.png, and the oxbows into world/layout.json.
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from numba import njit

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "world") + "/"
OUT = ROOT + "maps/"
SEA = 0.02
lay = json.load(open(ROOT + "layout.json"))
lm = next(l for l in lay["landmasses"] if l["name"] == "main_island")
PEAK = lm["peak"]
SIZE = lm["size"]
C = lm["center"]
# the painted source (kept separately, so the tool can be rerun)
src = np.asarray(Image.open(OUT + "src/main_island_painted.png")).astype(np.float64) / 65535.0
N = src.shape[0]
RES = SIZE / N
land = src > SEA
h0 = np.where(land, (src - SEA) / (1 - SEA) * PEAK, 0.0)
mw = lm["river_mouths"][0]
mouth_px = (int((mw[1] - C[1]) / SIZE * N + N / 2), int((mw[0] - C[0]) / SIZE * N + N / 2))

NB = np.array([(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)], np.int64)
ND = np.array([math.sqrt(2), 1, math.sqrt(2), 1, 1, math.sqrt(2), 1, math.sqrt(2)])


@njit(cache=True)
def flood_route(h, land, eps):
    """Priority flood from the coast (Barnes 2014): receivers and an order
    with receivers before donors; depressions are filled (h raised) just
    enough to drain."""
    n = h.shape[0]
    recv = -np.ones((n, n, 2), np.int64)
    seen = np.zeros((n, n), np.bool_)
    order = np.empty((n * n, 2), np.int64)
    cnt = 0
    # binary heap of (key, y, x)
    hk = np.empty(n * n + 8, np.float64)
    hy = np.empty(n * n + 8, np.int64)
    hx = np.empty(n * n + 8, np.int64)
    size = 0
    for y in range(1, n - 1):
        for x in range(1, n - 1):
            if not land[y, x]:
                continue
            coast = False
            for k in range(8):
                if not land[y + NB[k, 0], x + NB[k, 1]]:
                    coast = True
                    recv[y, x, 0] = y + NB[k, 0]
                    recv[y, x, 1] = x + NB[k, 1]
                    break
            if coast:
                seen[y, x] = True
                # push
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
    while size > 0:
        y = hy[0]; x = hx[0]; key = hk[0]
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
    """Re-point each cell at a lower neighbour: the steepest, or (stochastic)
    one picked at random weighted by slope squared, which keeps channels from
    lining up with the grid's eight directions."""
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
def stream_power(h, land, order, recv, area, uplift, K, dt, res):
    """One implicit step of dh/dt = U - K A^0.5 S (Braun & Willett 2013),
    receivers before donors; the coast stays at sea level."""
    n = h.shape[0]
    for c in range(order.shape[0]):
        y = order[c, 0]; x = order[c, 1]
        ry = recv[y, x, 0]; rx = recv[y, x, 1]
        hr = h[ry, rx] if land[ry, rx] else 0.0
        d = res * (math.sqrt(2.0) if (ry != y and rx != x) else 1.0)
        f = K * dt * math.sqrt(area[y, x]) / d
        h[y, x] = (h[y, x] + uplift[y, x] * dt + f * hr) / (1.0 + f)
        if h[y, x] < hr:
            h[y, x] = hr + 1e-3
    return h


@njit(cache=True)
def talus(h, land, res, slope_max, iters):
    """Thermal erosion: wherever ground is steeper than the angle of repose
    to a neighbour, half the excess slides down to it. Peaks and ridges round
    off and cliffs stay at realistic angles instead of spikes."""
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
                    d = h[y, x] - h[yy, xx]
                    if d > lim:
                        m = 0.25 * (d - lim)
                        h[y, x] -= m
                        h[yy, xx] += m
    return h


def diffuse(h, land, kappa, steps):
    for _ in range(steps):
        lap = ndimage.laplace(h)
        h = np.where(land, h + kappa * lap, h)
    return h


# --- erosion -------------------------------------------------------------
# uplift follows the painted relief (smoothed), so the range, the mesa and
# the lowlands keep their heights; the painted rivers are sunk a little first
# so the drainage organises around them
t_h = h0.copy()
uplift = ndimage.gaussian_filter(h0, 6) / max(h0.max(), 1.0)
uplift = np.where(land, uplift, 0.0)
# erosion only (the painted map supplies the large-scale relief, restored
# below): valleys incise fastest where the most water runs, so the slopes
# break up into branching ridges, spurs and valleys
K = 2.0e-5
DT = 1000.0
h = t_h.copy()
steps = 80
no_uplift = np.zeros_like(h)
for it in range(steps):
    recv, order = flood_route(h, land, 1e-4)
    recv = steepest(h, land, order, recv, True, it)
    area = accumulate(order, recv, land, RES * RES)
    h = stream_power(h, land, order, recv, area, no_uplift, K, DT, RES)
    h = diffuse(h, land, 0.06, 1)
    if it % 40 == 0:
        print("step", it, "max", round(h.max(), 1), file=sys.stderr)

# keep the painted large-scale shape: rescale the eroded relief so that its
# smoothed envelope matches the painted one (the erosion adds the valleys,
# ridges and spurs between)
blur = 10
env_src = ndimage.gaussian_filter(h0, blur)
env_er = ndimage.gaussian_filter(h, blur)
ratio = np.where(env_er > 1.0, env_src / np.maximum(env_er, 1.0), 1.0)
ratio = np.clip(ratio, 0.6, 1.8)
hf = np.where(land, h * ratio, 0.0)
# blend toward the painted map near the coast (keep beaches and shelves) and
# keep a little of the painted surface everywhere
coast_d = ndimage.distance_transform_edt(land) * RES
w = np.clip(coast_d / 1500.0, 0, 1)
hf = np.where(land, hf * w + h0 * (1 - w), 0.0)
hf = np.where(land, np.maximum(hf, 0.6), 0.0)
hf = talus(hf, land, RES, math.tan(math.radians(38.0)), 40)
hf = diffuse(hf, land, 0.1, 3)

# --- rivers from the eroded terrain's own drainage ------------------------
hfill = hf.copy()
recv, order = flood_route(hfill, land, 1e-4)
recv = steepest(hfill, land, order, recv, False, 0)   # (on the filled surface, consistent with the order)
area = accumulate(order, recv, land, RES * RES)
# the mouth: the coastal cell nearest the layout's mouth with the most water
best = None
for dy in range(-30, 31):
    for dx in range(-30, 31):
        y, x = mouth_px[0] + dy, mouth_px[1] + dx
        if land[y, x] and coast_d[y, x] < RES * 1.6 and (best is None or area[y, x] > area[best]):
            best = (y, x)
mouth = best
# its catchment
inside = np.zeros((N, N), bool)
inside[mouth] = True
for c in range(order.shape[0]):
    y, x = order[c]
    ry, rx = recv[y, x]
    if ry >= 0 and land[ry, rx] and inside[ry, rx]:
        inside[y, x] = True
print("mouth", mouth, "catchment km2", round(inside.sum() * RES * RES / 1e6), file=sys.stderr)


def network(thr):
    ch = inside & (area >= thr)
    donors = np.zeros((N, N), np.int32)
    ys, xs = np.nonzero(ch)
    for y, x in zip(ys, xs):
        ry, rx = recv[y, x]
        if ry >= 0 and ch[ry, rx]:
            donors[ry, rx] += 1
    heads = int(((donors == 0) & ch).sum())
    return ch, donors, heads


target_heads = int(sys.argv[1]) if len(sys.argv) > 1 else 18
lo, hi = 1e6, 5e9
for _ in range(40):
    mid = math.sqrt(lo * hi)
    _, _, hd = network(mid)
    if hd > target_heads:
        lo = mid
    else:
        hi = mid
ch, donors, heads = network(hi)
print("threshold km2", round(hi / 1e6, 1), "heads", heads, file=sys.stderr)

# paths: from every head (and every junction) down to the next junction or the mouth
def path_from(y, x):
    p = [(y, x)]
    while True:
        ry, rx = recv[y, x]
        if ry < 0 or not land[ry, rx] or (y, x) == mouth:
            break
        p.append((ry, rx))
        if donors[ry, rx] > 1 or (ry, rx) == mouth:
            break
        y, x = ry, rx
    return p

starts = [tuple(v) for v in np.argwhere(ch & ((donors == 0) | (donors > 1)))]
paths = []
for s in starts:
    if s == mouth:
        continue
    p = path_from(*s)
    if len(p) >= 2:
        paths.append(p)


def smooth(pts, passes):
    for _ in range(passes):
        q = [pts[0]]
        for a, b in zip(pts[:-1], pts[1:]):
            q.append(0.75 * a + 0.25 * b)
            q.append(0.25 * a + 0.75 * b)
        q.append(pts[-1])
        pts = np.array(q)
    return pts


rng = np.random.default_rng(11)
img = Image.new("L", (N * 2, N * 2), 0)
dr = ImageDraw.Draw(img)
curves = []        # (pts in pixels, half width m) for every river reach
bends = []         # candidate oxbow sites: (path index, apex index, lam, amp, side)
for p in paths:
    pts = np.array([(x + 0.5, y + 0.5) for (y, x) in p], float)
    if len(pts) > 3:
        for _ in range(8):   # average out the cell-to-cell zigzag, ends fixed
            pts[1:-1] = 0.25 * pts[:-2] + 0.5 * pts[1:-1] + 0.25 * pts[2:]
        pts = smooth(pts, 3)
    km2 = area[p[-1]] / 1e6
    hw = 4 + 2.2 * math.sqrt(km2)
    # meanders where the land is flat: bends about 14 channel widths long
    # (never shorter than the bake's grid can carry), leaning downstream,
    # their length and swing wandering so no two match; tapering to nothing
    # at both ends (junctions and the mouth)
    if len(pts) > 8:
        seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
        s = np.concatenate([[0], np.cumsum(seg)]) * RES
        total = s[-1]
        tan = np.gradient(pts, axis=0)
        tan /= np.maximum(np.linalg.norm(tan, axis=1, keepdims=True), 1e-9)
        nrm = np.stack([-tan[:, 1], tan[:, 0]], 1)
        lam = max(14 * 2 * hw, 3200.0) * rng.uniform(0.85, 1.2)
        idx = np.clip((np.arange(len(pts)) * (len(p) - 1) / max(len(pts) - 1, 1)).astype(int), 0, len(p) - 1)
        elev = np.array([hf[p[i]] for i in idx])
        slope = np.abs(np.gradient(elev)) / np.maximum(np.gradient(s), 1.0)
        flat = 1.0 - np.clip((slope - 0.004) / 0.02, 0, 1)
        flat = ndimage.gaussian_filter1d(flat, 6)
        stretch = 1 + 0.3 * np.sin(s / (lam * 2.3) + rng.uniform(0, 6.3))
        ph = np.concatenate([[0], np.cumsum(np.diff(s) / (lam * stretch[1:]))]) * 2 * math.pi + rng.uniform(0, 2 * math.pi)
        wander = 1 + 0.3 * np.sin(s / (lam * 3.1) + rng.uniform(0, 6.3))
        amp = 0.27 * lam * flat * wander * float(os.environ.get("MEANDER", "1"))
        taper = np.clip(s / lam, 0, 1) * np.clip((total - s) / lam, 0, 1)
        a_t = amp * taper
        pts = pts + (nrm * (a_t * np.sin(ph))[:, None] + tan * (0.35 * a_t * np.cos(ph))[:, None]) / RES
        # apexes of the strongest bends: oxbow sites
        apex = np.nonzero((np.abs(np.sin(ph)) > 0.995) & (a_t > 0.6 * 0.27 * lam))[0]
        last = -10**9
        for i in apex:
            if s[i] - last > lam * 0.8:
                bends.append((len(curves), i, lam, a_t[i], float(np.sign(np.sin(ph[i])))))
                last = s[i]
    curves.append((pts, hw))
    dr.line([(px * 2, py * 2) for px, py in pts], fill=255, width=5, joint="curve")

# oxbow lakes: each a copy of a bend's loop, cut off and left behind outward
# of today's channel (meanders migrate outward), shortened into a crescent
from scipy.spatial import cKDTree
allpts = np.concatenate([c[0] for c in curves])
tree = cKDTree(allpts)
oxbows = []
for ci, i, lam, a, side in bends:
    pts, hw = curves[ci]
    half = int(len(pts) * (0.32 * lam) / max(1.0, np.linalg.norm(np.diff(pts, axis=0), axis=1).sum() * RES))
    lo, hi = i - half, i + half
    if lo < 2 or hi > len(pts) - 3:
        continue
    tan = pts[min(i + 2, len(pts) - 1)] - pts[max(i - 2, 0)]
    tan /= max(np.linalg.norm(tan), 1e-9)
    out_dir = np.array([-tan[1], tan[0]]) * side
    found = None
    for push, slide in ((0.9, 0.25), (1.2, 0.15), (0.7, 0.35), (1.5, 0.3)):
        loop = pts[lo:hi + 1] + (out_dir * (push * a + 3 * hw) + tan * slide * lam) / RES
        # clear of every river by a few widths, on low, fairly flat floodplain
        d, _ = tree.query(loop)
        yy = np.clip(loop[:, 1].astype(int), 0, N - 1); xx = np.clip(loop[:, 0].astype(int), 0, N - 1)
        if d.min() * RES > 2.5 * hw + 150.0 and land[yy, xx].all() and coast_d[yy, xx].min() > 600.0 \
                and np.ptp(hf[yy, xx]) < 60.0 and hf[yy, xx].max() < 400.0:
            found = loop
            break
    if found is None:
        continue
    loop = found
    k = max(len(loop) // 24, 1)
    world_pts = [[round(C[0] + (x / N - 0.5) * SIZE, 1), round(C[1] + (y / N - 0.5) * SIZE, 1)] for x, y in loop[::k]]
    oxbows.append({"points": world_pts, "half_width": round(hw * 0.85, 1)})
    allpts = np.concatenate([allpts, loop]); tree = cKDTree(allpts)   # (oxbows don't overlap each other)
lm["oxbows"] = oxbows
print("oxbows", len(oxbows), "of", len(bends), "sites", file=sys.stderr)
riv = np.asarray(img.resize((N, N), Image.BILINEAR)) > 60
riv = riv & land
# no loops: fill the little holes where thick strokes meet at a junction
holes, nh = ndimage.label(~riv)
sizes = ndimage.sum(np.ones_like(riv), holes, range(nh + 1))
outer = holes[0, 0]
for k in range(1, nh + 1):
    if k != outer and sizes[k] < 400:
        riv[holes == k] = True
Image.fromarray((riv * 255).astype(np.uint8)).save(OUT + "main_island_rivers.png")
v = np.where(land, SEA + (1 - SEA) * np.clip(hf / PEAK, 0, 1), 0)
Image.fromarray((np.clip(v, 0, 1) * 65535).astype(np.uint16)).save(OUT + "main_island_height.png")
mx = C[0] + ((mouth[1] + 0.5) / N - 0.5) * SIZE
mz = C[1] + ((mouth[0] + 0.5) / N - 0.5) * SIZE
lm["river_mouths"] = [[round(mx), round(mz)]]
json.dump(lay, open(ROOT + "layout.json", "w"), indent=1)
print("done: heads", heads, "paths", len(paths), "max h", round(hf.max()), "mouth", lm["river_mouths"], file=sys.stderr)
