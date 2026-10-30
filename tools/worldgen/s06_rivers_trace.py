"""The river system, traced on the 10 m grid from the eroded drainage: the
biggest catchment on the main island drains through one mouth; the trunk
and its tributaries traced up their valleys, meandering where the floor is
flat, tributaries curving in to meet their river, stubs pruned."""
from .config import *
from .kernels import *

INPUTS = ['CELL', 'hf', 'owner', 'rng']
OUTPUTS = ['CELL', 'a_mouth', 'hf', 'main_id', 'mouth', 'owner', 'rivers', 'rng', 'slope']


def run(ctx):
    CELL = ctx['CELL']
    hf = ctx['hf']
    owner = ctx['owner']
    rng = ctx['rng']
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
        return river_half_width(area_, a_mouth)
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
    return {'CELL': CELL, 'a_mouth': a_mouth, 'hf': hf, 'main_id': main_id, 'mouth': mouth, 'owner': owner, 'rivers': rivers, 'rng': rng, 'slope': slope}
