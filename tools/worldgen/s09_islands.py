"""islands in the trunk where it runs wide and gentle through the lowlands
(away from the mouth and from confluences): the channel opens out round
each, a teardrop of sand and grass, blunt upstream, tapering downstream"""
from .config import *
from .kernels import *

INPUTS = ['hf', 'rivers']
OUTPUTS = ['hf', 'islands', 'rivers']


def run(ctx):
    hf = ctx['hf']
    rivers = ctx['rivers']
    # islands in the trunk where it runs wide and gentle through the lowlands
    # (away from the mouth and from confluences): the channel opens out round
    # each, a teardrop of sand and grass, blunt upstream, tapering downstream
    trunk_ = rivers[0]
    arc_t = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(trunk_["pts"], axis=0), axis=1))])
    joins_t = [int(np.argmin(np.linalg.norm(trunk_["pts"] - rv["pts"][-1], axis=1))) for rv in rivers if rv["joins"] == 0]
    islands = []
    order_ = np.argsort(-trunk_["hw"])
    for k in order_:
        if len(islands) >= 4:
            break
        hw0 = float(trunk_["hw"][k])
        if hw0 < 24.0 or trunk_["level"][k] > 90.0 or arc_t[-1] - arc_t[k] < 700.0 or arc_t[k] < 500.0:
            continue
        if any(abs(arc_t[k] - arc_t[j]) < 250.0 for j in joins_t) or any(abs(arc_t[k] - i_["s"]) < 600.0 for i_ in islands):
            continue
        k0, k1 = max(k - 6, 0), min(k + 6, len(arc_t) - 1)
        if trunk_["level"][k0] - trunk_["level"][k1] > 1.5:
            continue   # (not where it runs steep)
        t_ = trunk_["pts"][k1] - trunk_["pts"][k0]
        t_ /= max(np.linalg.norm(t_), 1e-9)
        islands.append({"s": float(arc_t[k]), "k": int(k), "length": 5.0 * hw0, "width": 0.45 * hw0,
                        "x": float(trunk_["pts"][k][0]), "z": float(trunk_["pts"][k][1]), "dx": float(t_[0]), "dz": float(t_[1]),
                        "top": float(trunk_["level"][k]) + 1.4})
    for i_ in islands:
        d_ = arc_t - i_["s"]
        bump = np.exp(-(d_ / (0.6 * i_["length"])) ** 2)
        trunk_["hw"] = trunk_["hw"] * (1.0 + 0.5 * bump)   # (room to flow round it)
    log("islands:", len(islands))
    for ri_, rv in enumerate(rivers):   # how far below the ground each river runs (before carving)
        cut_ = bilinear(hf, rv["pts"][:, 0], rv["pts"][:, 1]) - rv["level"]
        log("  river %d: below ground median %.1f m, 90%% %.1f m, max %.1f m" % (ri_, np.median(cut_), np.percentile(cut_, 90), cut_.max()))
    return {'hf': hf, 'islands': islands, 'rivers': rivers}
