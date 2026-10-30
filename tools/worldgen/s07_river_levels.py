"""Widths, depths and the water surface: the downhill profile closest to the
ground under each channel (tributaries ending at their river's level, the
trunk at sea level), the falls where it runs steep, centrelines that never
double back or bend tighter than they could."""
from .config import *
from .kernels import *

INPUTS = ['a_mouth', 'hf', 'rivers']
OUTPUTS = ['falls', 'hf', 'rivers']


def run(ctx):
    a_mouth = ctx['a_mouth']
    def half_width(area_):
        return river_half_width(area_, a_mouth)
    hf = ctx['hf']
    rivers = ctx['rivers']
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
            # falling in a step where it reaches the floodplain or the confluence.
            # Its natural fall is kept everywhere else.
            mp_ = main["pts"]
            d2_ = ((rv["pts"][:, None, :] - mp_[None, :, :]) ** 2).sum(-1)
            nk = np.argmin(d2_, axis=1)
            dist_ = np.sqrt(d2_[np.arange(len(nk)), nk])
            hw_mn = main["hw"][nk]
            plain = main["level"][nk] + 0.5 + 0.012 * np.maximum(dist_ - 1.3 * hw_mn, 0.0)
            across_plain = dist_ < hw_mn + 3.0 * rv["hw"] + 50.0
            target = np.where(across_plain, np.minimum(rv["level"], plain), rv["level"])
            target[-1] = main["level"][k]
            # (only the first 6 m of it: a side valley hanging higher than that
            # above its river's floodplain drops the rest in a waterfall where it
            # meets it, rather than scouring a trench far back up its course)
            need = np.maximum(rv["level"] - target, 0.0)
            low = np.minimum(need, 6.0)
            ds_ = np.linalg.norm(np.diff(rv["pts"], axis=0), axis=1)
            for i in range(len(low) - 2, -1, -1):
                low[i] = max(low[i], low[i + 1] - 0.01 * ds_[i])
            low = np.maximum(low, need)
            rv["level"] = rv["level"] - low
            rv["smooth"] = np.maximum(rv["smooth"] - low, main["smooth"][k])
            rv["level"][-1] = main["level"][k]
            rv["level"] = np.minimum.accumulate(np.maximum(rv["level"], main["level"][k]))
        else:
            rv["level"][-1] = min(rv["level"][-1], 0.0)
            rv["level"] = np.minimum.accumulate(rv["level"])
            # an estuary: the trunk comes down to the sea gently over its last
            # kilometre and a half (2.2 m per km, 0.05 m at the coast), its valley
            # floor with it, rather than running down a beach
            # (only its last 1.5 km: whatever lowering that needs is eased out up
            # its course at 1 cm a metre; above that it keeps its natural fall)
            arc_ = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(rv["pts"], axis=0), axis=1))])
            d_end = arc_[-1] - arc_
            tide = 0.05 + 0.0022 * d_end
            low = np.where(d_end < 1500.0, np.maximum(rv["level"] - tide, 0.0), 0.0)
            ds_ = np.diff(arc_)
            for i in range(len(low) - 2, -1, -1):
                low[i] = max(low[i], low[i + 1] - 0.01 * ds_[i])
            rv["level"] = np.minimum.accumulate(rv["level"] - low)
            rv["smooth"] = np.maximum(rv["smooth"] - low, rv["level"])
    return {'falls': falls, 'hf': hf, 'rivers': rivers}
