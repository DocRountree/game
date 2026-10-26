#!/usr/bin/env python3
"""Build src/systems/atmosphere/bright_stars.tres: naked-eye stars and Messier objects.

Inputs:
  bsc5-short.json  from https://github.com/brettonw/YaleBrightStarCatalog
                   (MIT-licensed JSON of the public-domain Yale Bright Star Catalog, J2000)
  messier.json     from https://github.com/ofrohn/d3-celestial (data/, BSD-3-Clause)

    python3 tools/build_star_catalog.py path/to/bsc5-short.json path/to/messier.json

Stars: every star down to magnitude 6.5, three floats each:
  right ascension (rad), declination (rad), visual magnitude.
Deep-sky objects: six floats each:
  right ascension (rad), declination (rad), magnitude,
  major and minor diameter (arcmin), position angle (deg, north through east).
"""
import json
import math
import re
import sys
from pathlib import Path

MAG_LIMIT = 6.5
OUT = Path(__file__).resolve().parent.parent / "src/systems/atmosphere/bright_stars.tres"

# The source has no orientations; these are the obviously elongated ones.
POSITION_ANGLES = {"M31": 35.0, "M33": 23.0, "M81": 157.0, "M82": 65.0, "M104": 90.0}


def parse_ra(text):
    h, m, s = (float(x) for x in re.findall(r"[\d.]+", text))
    return (h + m / 60 + s / 3600) / 24 * 2 * math.pi


def parse_dec(text):
    d, m, s = (float(x) for x in re.findall(r"[\d.]+", text))
    sign = -1.0 if text.strip().startswith("-") else 1.0
    return sign * math.radians(d + m / 60 + s / 3600)


def floats(values):
    return ", ".join(f"{v:.5g}" for v in values)


def main():
    stars = []
    for s in json.load(open(sys.argv[1], encoding="utf-8")):
        if "V" in s and "RA" in s and "Dec" in s and float(s["V"]) <= MAG_LIMIT:
            stars += [parse_ra(s["RA"]), parse_dec(s["Dec"]), float(s["V"])]

    deep_sky = []
    for f in json.load(open(sys.argv[2], encoding="utf-8"))["features"]:
        p = f["properties"]
        ra_deg, dec_deg = f["geometry"]["coordinates"]
        dims = [float(x) for x in re.findall(r"[\d.]+", p.get("dim") or "1")]
        major = dims[0]
        minor = dims[1] if len(dims) > 1 else major
        mag = float(p["mag"]) if p.get("mag") not in (None, "") else 8.0
        deep_sky += [math.radians(ra_deg % 360.0), math.radians(dec_deg), mag, major, minor,
                     POSITION_ANGLES.get(p["name"], 0.0)]

    OUT.write_text(
        '[gd_resource type="Resource" script_class="StarCatalog" format=3]\n\n'
        '[ext_resource type="Script" path="res://src/systems/atmosphere/star_catalog.gd" id="1"]\n\n'
        "[resource]\n"
        'script = ExtResource("1")\n'
        f'source = "Stars: Yale Bright Star Catalog 5th ed. (public domain), J2000, V <= {MAG_LIMIT}. '
        'Messier objects: d3-celestial (c) 2015 Olaf Frohn, BSD-3-Clause, see docs/THIRD_PARTY.md."\n'
        f"stars = PackedFloat32Array({floats(stars)})\n"
        f"deep_sky = PackedFloat32Array({floats(deep_sky)})\n",
        encoding="utf-8",
    )
    print(f"wrote {len(stars) // 3} stars and {len(deep_sky) // 6} deep-sky objects to {OUT}")


if __name__ == "__main__":
    main()
