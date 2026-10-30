"""The rivers carved into the 2.5 m heights together with their water level, so
the water always lies in its bed: each river's bed, banks and floodplain
(blended where valleys overlap, each channel cut through the others' banks),
the trunk's channel carried out to sea, the banks smoothed and held above
the water, the islands raised out of the channel."""
from .config import *
from .kernels import *

INPUTS = ['hf', 'islands', 'rivers']
OUTPUTS = ['BED', 'Wt', 'hf', 'islands', 'rivers']


def run(ctx):
    hf = ctx['hf']
    islands = ctx['islands']
    rivers = ctx['rivers']
    SW = np.zeros((N, N), np.float32)
    ST = np.zeros((N, N), np.float32)
    Wt = np.zeros((N, N), np.float32)
    RM = np.full((N, N), 1e9, np.float32)
    CUT = np.full((N, N), 1e9, np.float32)
    BED = np.zeros((N, N), np.float32)
    CH = np.zeros((N, N), np.uint8)
    WL = np.zeros((N, N), np.float32)
    CC = np.zeros((N, N), np.float32)
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
        LNw = np.zeros_like(Tw)
        CNw = np.zeros_like(Tw)
        # the floodplain reaches far where the valley floor is flat; on steep ground
    # none (the river's banks rise straight into the valley's own sides, which
    # are left as they are, not shaved back into a flat-floored trench)
        sl = np.abs(np.gradient(ndimage.uniform_filter1d(rv["smooth"], 15))) / np.maximum(
            np.linalg.norm(np.gradient(p, axis=0), axis=1), 0.5)
        vr = 1.8 + 7.2 * np.clip(1.0 - (sl - 0.02) / 0.06, 0, 1)   # (in a steep valley the banks meet its own sides)
        # where it runs well below the ground (below a fall, down from a hanging
        # valley) the sides are laid back to a slope rather than cut sheer
        incised = np.maximum(bilinear(hf, p[:, 0], p[:, 1]) - rv["level"], 0.0)
        vr = np.maximum(vr, np.clip(1.6 + 1.6 * incised / np.maximum(rv["hw"], 1.0), 1.8, 8.5))
        vi = np.clip((incised - rv["depth"]) / (rv["depth"] + 2.0), 0.0, 1.0)
        carve_river(p[:, 0].copy(), p[:, 1].copy(), rv["level"], rv["smooth"], rv["hw"], rv["depth"], vr, vi, rv["cascade"], WORLD, N, x0, z0,
                    hf[z0:z1, x0:x1].astype(np.float32), Tw, Ww, Rw, LNw, CNw)
        blend_in(Tw, Ww, Rw, LNw, CNw, x0, z0, rv["joins"] >= 0, SW, ST, Wt, RM, CUT, BED, CH, WL, CC)
    T = np.where(SW > 0, ST / np.maximum(SW, 1e-30), 0.0).astype(np.float32)
    T = np.minimum(T, CUT)   # every channel cut through the banks of the others
    channel = CH > 0         # (the rivers' beds: sand and gravel, below)
    del ST, CUT, CH
    # blended in (the land beside the river pulled toward its floodplain, both
    # ways), except out at sea
    hf = np.where((SW > 0) & ((hf > -1.0) | (T < hf) | channel), hf + (T - hf) * Wt, hf)
    # the trunk's channel carried on out to sea (400 m, along its last 180 m)
    # until the seafloor is deeper, so no rim of beach is left across its mouth:
    # only the low beach and bar there are lowered, softly, never higher ground
    for rv in rivers:
        if rv["joins"] >= 0:
            continue
        pe = rv["pts"][-1]
        de = pe - rv["pts"][-30]
        de /= max(np.linalg.norm(de), 1e-9)
        hw_e, dep_e = float(rv["hw"][-1]), float(rv["depth"][-1])
        cell_f = WORLD / N
        lo_ = np.minimum(pe, pe + de * 400.0) - 1.3 * hw_e
        hi_ = np.maximum(pe, pe + de * 400.0) + 1.3 * hw_e
        i0, i1 = [int(np.clip((v + WORLD / 2) / cell_f, 0, N)) for v in (lo_[0], hi_[0])]
        j0, j1 = [int(np.clip((v + WORLD / 2) / cell_f, 0, N)) for v in (lo_[1], hi_[1])]
        gx, gz = np.meshgrid(np.arange(i0, i1) * cell_f - WORLD / 2, np.arange(j0, j1) * cell_f - WORLD / 2)
        along_ = (gx - pe[0]) * de[0] + (gz - pe[1]) * de[1]
        r_ = np.abs(-(gx - pe[0]) * de[1] + (gz - pe[1]) * de[0]) / hw_e
        win_ = hf[j0:j1, i0:i1]
        wgt_ = np.clip((1.0 - r_) / 0.4, 0, 1) * np.clip((400.0 - along_) / 150.0, 0, 1) \
            * np.clip((along_ + hw_e) / hw_e, 0, 1) * np.clip((1.5 - win_) / 0.9, 0, 1)
        bed_ = -dep_e * np.clip(1.0 - r_ * r_, 0.0, 1.0) - 0.4
        hf[j0:j1, i0:i1] = np.minimum(win_, win_ + (bed_ - win_) * wgt_ * wgt_ * (3.0 - 2.0 * wgt_))
    # the banks smoothed: a light blur over the ground beside every channel (not
    # in the water, nor down a cascade's rock), so no step or sawtooth is left
    # along them where the rivers' carving meets; then held above the water
    # again (as the carve has them), so none of it can leak out (not down by
    # the sea: no rim of beach across the mouth)
    bank_m = np.clip((RM - 1.0) / 0.3, 0.0, 1.0)
    bank_m = bank_m * bank_m * (3.0 - 2.0 * bank_m) * np.clip((5.0 - RM) / 2.0, 0.0, 1.0) * (1.0 - CC)
    hf = hf + (ndimage.gaussian_filter(hf.astype(np.float32), 1.2) - hf) * bank_m
    del bank_m
    b_ = 0.15 * np.clip(WL / 2.5, 0.0, 1.0) + 1.35 * CC
    y_ = np.clip((RM - 1.0) / 0.15, 0.0, 1.0)
    z_ = np.clip((RM - 1.45) / 0.4, 0.0, 1.0)
    hf = np.where((RM >= 1.0) & (RM < 2.0) & (WL > 0.4), np.maximum(hf, WL + b_ * y_ * y_ * (3.0 - 2.0 * y_) - (b_ + 2.0) * z_ * z_ * (3.0 - 2.0 * z_)), hf)
    del b_, y_, z_, RM, WL, CC
    # the islands raised out of the channel: a smooth mound, its shore where it
    # comes up through the water (0.86 of the way out), its foot sloping on down
    # into the bed (no step anywhere, so the 2.5 m grid draws its edge smoothly)
    cell_f = WORLD / N
    for i_ in islands:
        half = 0.5 * i_["length"]
        ext = 1.6 * half + 2.0 * i_["width"] + 10.0
        i0, i1 = [int(np.clip((v + WORLD / 2) / cell_f, 0, N)) for v in (i_["x"] - ext, i_["x"] + ext)]
        j0, j1 = [int(np.clip((v + WORLD / 2) / cell_f, 0, N)) for v in (i_["z"] - ext, i_["z"] + ext)]
        gx, gz = np.meshgrid(np.arange(i0, i1) * cell_f - WORLD / 2, np.arange(j0, j1) * cell_f - WORLD / 2)
        a_ = ((gx - i_["x"]) * i_["dx"] + (gz - i_["z"]) * i_["dz"]) / half          # -1 upstream .. 1 downstream
        b_ = (-(gx - i_["x"]) * i_["dz"] + (gz - i_["z"]) * i_["dx"])
        wid = i_["width"] * np.clip(1.15 - 0.45 * np.clip(a_, -1.0, 1.0), 0.3, 1.3)   # blunt head, tapering tail
        q_ = np.sqrt(a_ * a_ + (b_ / wid) ** 2)   # 0 at its middle
        s_ = np.clip((q_ - 0.6) / 0.9, 0.0, 1.0)
        mound = i_["top"] + 0.4 * np.clip((0.6 - q_) / 0.6, 0, 1) - 7.0 * s_ * s_ * (3.0 - 2.0 * s_) \
            - 30.0 * np.maximum(q_ - 1.5, 0.0)   # (and on down, out of the way: well downstream the river is lower)
        win_ = hf[j0:j1, i0:i1]
        hf[j0:j1, i0:i1] = np.maximum(win_, mound)
    del SW, T
    log("rivers: %d, %d points" % (len(rivers), sum(len(r["pts"]) for r in rivers)))
    return {'BED': BED, 'Wt': Wt, 'hf': hf, 'islands': islands, 'rivers': rivers}
