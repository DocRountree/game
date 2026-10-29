#!/usr/bin/env python3
"""Image metrics for the benchmark renders in a directory (tools/bench/run.sh):
for every VIEW.png with a VIEW_mask.png (the rivers' water drawn magenta),
the water's coverage and mean colour (CIELAB), its brightest pixel, how much
of it is foam-white, and how mid-toned that foam is (a cloud-like texture has
many mid-tones; lace has few); and each view's GPU/CPU timing."""
import json, os, sys
import numpy as np
from PIL import Image


def lab(rgb):
    rgb = rgb / 255.0
    lin = np.where(rgb > 0.04045, ((rgb + 0.055) / 1.055) ** 2.4, rgb / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = lin @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def water_mask(path):
    m = np.asarray(Image.open(path).convert("RGB")).astype(int)
    return (m[..., 0] > 200) & (m[..., 1] < 60) & (m[..., 2] > 200)


def stats(d, view):
    img = np.asarray(Image.open(os.path.join(d, view + ".png")).convert("RGB")).astype(float)
    mp = os.path.join(d, view + "_mask.png")
    if not os.path.exists(mp):
        return None
    mask = water_mask(mp)
    n = int(mask.sum())
    if n < 200:
        return {"water_px": n}
    px = img[mask]
    L = lab(px)
    lum = px @ np.array([0.2126, 0.7152, 0.0722])
    foam = (px.min(axis=1) > 175) & (lum > 190)   # near-white
    mid = ((px.min(axis=1) > 120) & ~foam).sum()  # grey-white: partial foam
    return {
        "water_px": n, "coverage": round(n / mask.size, 3),
        "lab_mean": [round(float(x), 1) for x in L.mean(0)],
        "peak_lum": round(float(lum.max()), 0),
        "foam_frac": round(float(foam.mean()), 3),
        "foam_midtone_share": round(float(mid / max(mid + foam.sum(), 1)), 3),
    }


def main():
    d = sys.argv[1]
    timing = {}
    rp = os.path.join(d, "report.jsonl")
    if os.path.exists(rp):
        for line in open(rp):
            j = json.loads(line)
            timing.setdefault(j["view"], j)
    out = {}
    for f in sorted(os.listdir(d)):
        if f.endswith(".png") and not f.endswith("_mask.png"):
            v = f[:-4]
            out[v] = {"timing": {k: timing.get(v, {}).get(k) for k in ("gpu_ms", "cpu_ms", "draw_calls", "triangles")}}
            s = stats(d, v)
            if s:
                out[v].update(s)
    json.dump(out, open(os.path.join(d, "metrics.json"), "w"), indent=1)
    for v, s in out.items():
        print(v, json.dumps(s))


main()
