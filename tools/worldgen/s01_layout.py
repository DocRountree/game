"""Layout at 10 m: the main island (~8 km, a mountain range off-centre down its
spine, a valley for the river), the peripheral island, the volcanic cones,
the archipelago's islets along an arc and the southern group; uplift."""
from .config import *
from .kernels import *

INPUTS = ['rng']
OUTPUTS = ['CELL', 'H', 'X', 'Z', 'arc_pts', 'islet_ids', 'landmasses', 'owner', 'rng', 'south', 'volcano_centres']


def run(ctx):
    rng = ctx['rng']
    X, Z = world_coords(M)
    CELL = WORLD / M
    warp = field_fbm(X, Z, 2000.0, 4, SEED + 1)
    warp2 = field_fbm(X, Z, 500.0, 3, SEED + 2)
    H = np.full((M, M), -1e9)
    owner = np.zeros((M, M), np.int32)
    landmasses = []
    def add(field, kind, cx, cz, radius):
        nonlocal H
        k = len(landmasses) + 1
        landmasses.append({"kind": kind, "center": [round(cx, 1), round(cz, 1)], "radius": round(radius, 1)})
        better = field > H
        owner[better] = k
        H = np.where(better, field, H)
    def island(kind, cx, cz, r, profile, wob, elong, seed, reach=2.2):
        """A landmass computed in a window around it: d is its distance from the
        centre in coast radii, stretched by elong along a random axis and wobbled
        by noise at its own scale (so small islands aren't circles either)."""
        nonlocal H
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
    # the mountains a third taller (the lowlands, below 40 m, as they were)
    x_ = np.clip((H - 40.0) / 310.0, 0, 1)
    H = np.where(H > 0.0, H * (1.0 + 0.35 * x_ * x_ * (3.0 - 2.0 * x_)), H)
    del x_
    return {'CELL': CELL, 'H': H, 'X': X, 'Z': Z, 'arc_pts': arc_pts, 'islet_ids': islet_ids, 'landmasses': landmasses, 'owner': owner, 'rng': rng, 'south': south, 'volcano_centres': volcano_centres}
