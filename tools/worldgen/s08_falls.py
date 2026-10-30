"""Each fall made one steep drop: the water level held to its lip and then
down the face, rounded over the lip and into its foot, as steep as the
2.5 m grid draws cleanly (its run 0.3 of its height, at least 3 m), into the
plunge pool. It is sampled finely down the face (a point every 0.25 m of
the drop), so the carve cuts it cleanly and the game can break the water
over it into a mosaic of little falls over ledges (RiverRibbons). riser:
how far down the face each point is (0 at its lip, 1 at its foot; -1 off
it); cascade: 1 on and near a fall, easing to 0 over 12 m either side (the
carve keeps the banks sharp and high there)."""
from .config import *
from .kernels import *

INPUTS = ['falls', 'rivers']
OUTPUTS = ['rivers']


def run(ctx):
    falls = ctx['falls']
    rivers = ctx['rivers']
    # Each fall made one steep drop: the water level held to its lip and then
    # down the face, rounded over the lip and into its foot, as steep as the
    # 2.5 m grid draws cleanly (its run 0.3 of its height, at least 3 m), into the
    # plunge pool. It is sampled finely down the face (a point every 0.25 m of
    # the drop), so the carve cuts it cleanly and the game can break the water
    # over it into a mosaic of little falls over ledges (RiverRibbons). riser:
    # how far down the face each point is (0 at its lip, 1 at its foot; -1 off
    # it); cascade: 1 on and near a fall, easing to 0 over 12 m either side (the
    # carve keeps the banks sharp and high there).
    FALL_ROW = 0.25      # (m of drop between the points down a fall)
    _ss = np.linspace(0.0, 1.0, 2001)
    _ss_v = _ss * _ss * (3.0 - 2.0 * _ss)   # (smoothstep, to invert)
    def with_falls(rv):
        p, L = rv["pts"], rv["level"]
        n = len(p)
        seg = np.linalg.norm(np.diff(p, axis=0), axis=1)
        arc = np.concatenate([[0], np.cumsum(seg)])
        keep = np.ones(n, bool)
        extra_s, extra_l, extra_r = [], [], []
        spans = []   # (s0, s1, drop)
        for k in range(n - 1):
            if L[k] - L[k + 1] <= 5.0:
                continue
            H = float(L[k] - L[k + 1])
            s0 = arc[k]
            run = min(float(np.clip(0.3 * H, 3.0, 12.0)), arc[-1] - s0 - 8.0)
            # down the face, a point every FALL_ROW of drop (and its lip and foot)
            dv = np.append(np.arange(0.0, H, FALL_ROW), H)
            t_ = np.interp(dv / H, _ss_v, _ss)
            extra_s.extend(s0 + t_ * run)
            extra_l.extend(L[k] - dv)
            extra_r.extend(t_)
            keep &= ~((arc > s0 - 0.5) & (arc < s0 + run + 2.0))
            spans.append((s0, s0 + run, H))
        s_all = np.concatenate([arc[keep], np.array(extra_s)])
        lv_all = np.concatenate([L[keep], np.array(extra_l)])
        ri_all = np.concatenate([np.full(keep.sum(), -1.0), np.array(extra_r)])
        o_ = np.argsort(s_all, kind="stable")
        s_all, lv_all, ri_all = s_all[o_], lv_all[o_], ri_all[o_]
        out = {
            "pts": np.stack([np.interp(s_all, arc, p[:, 0]), np.interp(s_all, arc, p[:, 1])], axis=1),
            "level": np.minimum.accumulate(lv_all),
            "riser": ri_all,
            # (a thin sheet down the face; the channel a touch narrower there)
            "depth": np.where(ri_all >= 0.0, 0.4, np.interp(s_all, arc, rv["depth"])),
            "hw": np.interp(s_all, arc, rv["hw"]) * np.where(ri_all >= 0.0, 0.95, 1.0),
            "area": np.interp(s_all, arc, rv["area"]),
            "smooth": np.interp(s_all, arc, rv["smooth"]),
        }
        casc = np.zeros(s_all.size)
        for a_, b_, _h in spans:
            out_ = np.maximum(np.maximum(a_ - 1.6 - s_all, s_all - b_ - 1.6), 0.0)
            casc = np.maximum(casc, np.clip(1.0 - out_ / 12.0, 0.0, 1.0))
        out["cascade"] = casc
        out["falls"] = [[int(np.argmin(np.abs(s_all - a_))), int(np.argmin(np.abs(s_all - b_)))] for a_, b_, _h in spans]
        out["feet"] = [f_[1] for f_ in out["falls"]]
        return out
    for rv in rivers:
        o_ = with_falls(rv)
        falls += len(o_["falls"])
        for key_ in ("pts", "level", "riser", "depth", "hw", "area", "smooth", "cascade", "falls"):
            rv[key_] = o_[key_]
        fall_at = o_["feet"]
        seg = np.linalg.norm(np.diff(rv["pts"], axis=0), axis=1)
        arc = np.concatenate([[0], np.cumsum(seg)])
        # the water thins in over a stream's first 250 m (as the game draws it):
        # the channel deepens in with it
        x = np.clip(arc / 250.0, 0, 1)
        rv["depth"] = rv["depth"] * np.maximum(x * x * (3 - 2 * x), 0.05)
        # coming up to each fall's lip the water runs shallow over the rock (the
        # channel's bed rising to the brink), so it goes over the lip at the top
        # of the face, not 3 m down it
        for f_ in rv["falls"]:
            hw0 = float(rv["hw"][f_[0]])
            d_ = arc[f_[0]] - arc
            y = np.clip(d_ / (1.5 * hw0 + 6.0), 0.0, 1.0)
            taper = np.where(d_ >= 0.0, y * y * (3.0 - 2.0 * y), 1.0)
            rv["depth"] = np.where(d_ >= 0.0, 0.5 + (rv["depth"] - 0.5) * np.maximum(taper, 0.0), rv["depth"])
        # a pool at the foot of each fall, wider and deeper (most in the
        # lowlands), where the water gathers before it picks up its current
        # again: as wide and deep as it gets right from the foot (so the water
        # coming down every part of the face lands in it), easing back further on
        for fi in fall_at:
            hw0 = float(rv["hw"][fi])
            grow = 1.0 if rv["level"][fi] < 120.0 else 0.55
            d_ = arc - arc[fi]
            bump = np.where(d_ >= 0.0, np.exp(-(np.maximum(d_ - 1.2 * hw0, 0.0) / (1.5 * hw0)) ** 2), 0.0)
            rv["hw"] = rv["hw"] * (1.0 + grow * np.where(d_ > 0.0, bump, 0.0))
            rv["depth"] = rv["depth"] + 1.5 * bump
    log("waterfalls:", falls)
    return {'rivers': rivers}
