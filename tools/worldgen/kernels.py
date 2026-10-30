"""Pure functions the stages share: noise, flow routing and erosion, the
river carve (most compiled with numba)."""
from .config import *


def river_half_width(area_, a_mouth):
    """A river's half width (m) for the area draining into it: 9 m across at
    the heads, ~130 m at the mouth (which drains a_mouth)."""
    return 4.5 + 60.0 * np.sqrt(np.clip(area_ / a_mouth, 0, 1))


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


def with_waterfall(g, base, rid):
    """A waterfall where the ground drops steeply: at the stream's steepest
    stretch (the most drop over 144 m, at least 12 m), the water follows the
    ground down to a lip halfway down it and falls sheer from there into the
    pool at its foot (so the gorge cut below a fall is only half as deep as
    the drop). A second, only where the ground drops a great deal (40 m) well
    away from the first. Elsewhere the water follows the smooth downhill
    profile (rapids, not a staircase)."""
    lvl = base.copy()
    n = len(g)
    w = 24
    if rid == 0 or n < 2 * w + 20:
        return lvl, 0
    drop = np.full(n, -1.0)
    drop[10:n - w - 10] = g[10:n - w - 10] - g[10 + w:n - 10]
    falls_ = 0
    for need in (12.0, 40.0):
        q = int(np.argmax(drop))
        if drop[q] < need:
            break
        m, k = q + w // 2, q + w
        lvl[m + 1:k + 1] = np.minimum(lvl[m + 1:k + 1], base[k])
        drop[max(q - 60, 0):min(k + 60, n)] = -1.0
        falls_ += 1
    return np.minimum.accumulate(lvl), falls_


@njit(cache=True)
def _seg_window(ax, az, bx, bz, reach, world, cell, x0, z0, hx, hz):
    i0 = max(int((min(ax, bx) - reach + world / 2) / cell) - x0, 0)
    i1 = min(int((max(ax, bx) + reach + world / 2) / cell) + 1 - x0, hx - 1)
    j0 = max(int((min(az, bz) - reach + world / 2) / cell) - z0, 0)
    j1 = min(int((max(az, bz) + reach + world / 2) / cell) + 1 - z0, hz - 1)
    return i0, i1, j0, j1


@njit(cache=True)
def carve_river(px_, pz_, L, Ls, HW, DP, VR, VI, CS, world, n, x0, z0, G, T, W, R, LNo, CNo):
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
    beside a mountain stream. Where it runs incised below the ground (VI: 0..1)
    its sides are laid back in a V (about 37 degrees) instead. Beyond its
    banks the ground (G) is only ever lowered, never built up (easing over to
    that between 1.3 and 2.4 half widths, so there is no step where it
    starts). Banks never stand lower than the water nearest them (L at the
    nearest reach), so a bank beside a waterfall's lip can't dip below the
    water going over it. Down a cascade (CS: 0..1) the blend is sharp, so
    each step is cut cleanly, and its banks stand higher: a channel of rock.
    W is how much of the ground is the river's, R the distance in half
    widths, LNo and CNo the water level and cascade weight of the nearest
    reach."""
    cell = world / n
    hz, hx = T.shape
    D = np.full((hz, hx), 1e9, np.float32)
    LN = np.zeros((hz, hx), np.float32)
    CN = np.zeros((hz, hx), np.float32)
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
                    LN[j, i] = L[k] + (L[k + 1] - L[k]) * u
                    CN[j, i] = CS[k] + (CS[k + 1] - CS[k]) * u
    SWr = np.zeros((hz, hx), np.float32)
    SL = np.zeros((hz, hx), np.float32)
    SLs = np.zeros((hz, hx), np.float32)
    SH = np.zeros((hz, hx), np.float32)
    SD = np.zeros((hz, hx), np.float32)
    SV = np.zeros((hz, hx), np.float32)
    SI = np.zeros((hz, hx), np.float32)
    for k in range(px_.size - 1):
        ax = px_[k]; az = pz_[k]; bx = px_[k + 1]; bz = pz_[k + 1]
        i0, i1, j0, j1 = _seg_window(ax, az, bx, bz, 9.0 * max(HW[k], HW[k + 1]), world, cell, x0, z0, hx, hz)
        abx = bx - ax; abz = bz - az
        ll = abx * abx + abz * abz + 1e-9
        sharp = max(CS[k], CS[k + 1])
        for j in range(j0, j1 + 1):
            pz = (j + z0) * cell - world / 2
            for i in range(i0, i1 + 1):
                dm = D[j, i]
                px = (i + x0) * cell - world / 2
                u = min(max(((px - ax) * abx + (pz - az) * abz) / ll, 0.0), 1.0)
                dx = px - (ax + abx * u); dz = pz - (az + abz * u)
                d = math.sqrt(dx * dx + dz * dz)
                e = (d - dm) / ((0.2 * dm + 0.5) * (1.0 - sharp) + 0.12 * sharp)
                if e > 9.0:
                    continue
                w = math.exp(-e)
                SWr[j, i] += w
                SL[j, i] += w * (L[k] + (L[k + 1] - L[k]) * u)
                SLs[j, i] += w * (Ls[k] + (Ls[k + 1] - Ls[k]) * u)
                SH[j, i] += w * (HW[k] + (HW[k + 1] - HW[k]) * u)
                SD[j, i] += w * (DP[k] + (DP[k + 1] - DP[k]) * u)
                SV[j, i] += w * (VR[k] + (VR[k + 1] - VR[k]) * u)
                SI[j, i] += w * (VI[k] + (VI[k + 1] - VI[k]) * u)
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
            water = lvl
            if r > 1.6:
                y = min((r - 1.6) / 1.9, 1.0)
                lvl += (SLs[j, i] / sw - lvl) * y * y * (3.0 - 2.0 * y)
            dep = SD[j, i] / sw
            if r < 1.0:
                tgt = lvl - dep * (1.0 - r * r)
            else:
                # the bank rises steeply out of the water, then the
                # floodplain climbs gently away
                x = min((r - 1.0) / max(0.3, 6.0 / hw), 1.0)   # (never steeper than the 2.5 m grid draws smoothly)
                bank = min(0.4 + 0.15 * dep, dep * 0.8) * x * (2.0 - x) * min(max(water / 2.5, 0.15), 1.0)   # (low by the sea: no ridge along an estuary)
                tgt = lvl + bank + max(r - 1.3, 0.0) * hw * 0.012
                vi = SI[j, i] / sw
                if vi > 0.0:
                    tgt += (water + bank + 0.75 * max(r - 1.3, 0.0) * hw - tgt) * vi
                # beyond the banks, easing over to only ever lowering the ground
                y = min(max((r - 1.3) / 1.1, 0.0), 1.0)
                tgt += (min(tgt, G[j, i]) - tgt) * y * y * (3.0 - 2.0 * y)
                # the banks never below the nearest water (low by the sea,
                # higher down a cascade); out past the water's reach, free
                ln = LN[j, i]
                b = 0.15 * min(max(ln / 2.5, 0.0), 1.0) + 1.35 * CN[j, i]
                y = min((r - 1.0) / 0.15, 1.0)
                z = min(max((r - 1.45) / 0.4, 0.0), 1.0)
                tgt = max(tgt, ln + b * y * y * (3.0 - 2.0 * y) - (b + 2.0) * z * z * (3.0 - 2.0 * z))
            x = min(max((r - 1.3) / (vr - 1.3), 0.0), 1.0)
            T[j, i] = tgt
            W[j, i] = 1.0 - x * x * (3.0 - 2.0 * x)
            R[j, i] = r
    LNo[:, :] = LN
    CNo[:, :] = CN


@njit(cache=True)
def blend_in(T, W, R, LNw, CNw, x0, z0, trib, SW, ST, WM, RM, CUT, BED, CH, WL, CC):
    """Add one river's ground to the network's: weighted by its claim on the
    ground (W^8), so where two rivers' valleys overlap the stronger takes over
    smoothly; a tributary's channel fades out inside the water of the rivers
    already carved (it ends inside one of them). Each river's own channel and
    banks are kept in CUT, so that they can be cut through the others' banks
    afterwards (a tributary keeps its width right into its river), easing off
    from 1 to 1.6 half widths out (no step where the cut stops); CH marks the
    channels themselves. BED is how much of the ground is a river's bed or
    bank (for the sand and gravel). RM is the distance (in half widths) from
    the nearest channel, WL and CC that reach's water level and cascade weight."""
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
            wc = min(max((1.6 - R[j, i]) / 0.6, 0.0), 1.0)
            if wc > 0.0:
                CUT[jj, ii] = min(CUT[jj, ii], T[j, i] + (1.0 - wc * wc * (3.0 - 2.0 * wc)) * 8.0)
            if R[j, i] < 1.1:
                CH[jj, ii] = 1
            BED[jj, ii] = max(BED[jj, ii], min(max((1.45 - R[j, i]) / 0.15, 0.0), 1.0))
            o = w ** 8
            SW[jj, ii] += o
            ST[jj, ii] += o * T[j, i]
            WM[jj, ii] = max(WM[jj, ii], w)
    for j in range(hz):
        for i in range(hx):
            if W[j, i] > 0.0 and R[j, i] < RM[j + z0, i + x0]:
                RM[j + z0, i + x0] = R[j, i]
                WL[j + z0, i + x0] = LNw[j, i]
                CC[j + z0, i + x0] = CNw[j, i]
