class_name RibbonCentreline
extends RefCounted
## Stage 1 of a river's ribbon (RiverRibbons): its centreline resampled
## (Catmull-Rom, so it stays smooth) about every STEP m, finer just above a
## fall's lip and keeping a fall's own close-set points; per sample its
## half width, depth, current, how much water there is and how far down a
## fall's face; and the ground distance along it. Then (frames()) the across
## direction at each sample and the bends' curvature, and (spread()) how far a
## tributary's water reaches over its banks coming into its river.

const STEP := 2.0          ## Distance between cross-sections (m).
const PRE_SPACING := 0.4   ## Just above a fall's lip, cross-sections this far apart (m).

var count := 0
var pts := PackedVector3Array()
var hw := PackedFloat32Array()
var dep := PackedFloat32Array()
var spd := PackedFloat32Array()
var fill := PackedFloat32Array()   ## How much water: thinning in over a river's first 250 m.
var ris := PackedFloat32Array()    ## How far down a fall's face (-1 off them).
var run := PackedFloat32Array()    ## Ground distance from the first sample (m).
var tans := PackedVector2Array()   ## Downstream across the ground (unit; frames()).
var bend := PackedFloat32Array()   ## Signed curvature (1/m, + turning left; frames()).
var spread := PackedFloat32Array() ## 0..1 (spread()).


static func resample(r: RiverData) -> RibbonCentreline:
	var c := RibbonCentreline.new()
	var src := r.points
	var arc := PackedFloat32Array([0.0])
	for k in range(1, src.size()):
		arc.append(arc[k - 1] + Vector2(src[k].x - src[k - 1].x, src[k].z - src[k - 1].z).length())
	var lips := PackedFloat32Array()   # (where each fall's lip is, along it)
	for jj in src.size() - 1:
		if r.riser[jj] < 0.0 and r.riser[jj + 1] >= 0.0:
			lips.append(arc[jj + 1])
	var samples: Array[Vector2] = []   # (segment, t)
	for jj in src.size() - 1:
		var step := STEP
		for l in lips:   # (just above a lip, finer: the rock its water parts round)
			if arc[jj] < l and arc[jj + 1] > l - FallFace.PRE - 1.0:
				step = PRE_SPACING
		var n := maxi(ceili((arc[jj + 1] - arc[jj]) / step), 1)
		for q in n:
			samples.append(Vector2(jj, float(q) / n))
	samples.append(Vector2(src.size() - 2, 1.0))
	c.count = samples.size()
	for k in c.count:
		var j := int(samples[k].x)
		var t := samples[k].y
		var s := lerpf(arc[j], arc[j + 1], t)
		var p0 := src[maxi(j - 1, 0)]
		var p1 := src[j]
		var p2 := src[j + 1]
		var p3 := src[mini(j + 2, src.size() - 1)]
		var p := 0.5 * (2.0 * p1 + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t)
		p.y = lerpf(p1.y, p2.y, t)   # (the surface itself never overshoots)
		c.pts.append(p)
		c.hw.append(lerpf(r.half_width[j], r.half_width[j + 1], t))
		c.dep.append(lerpf(r.depth[j], r.depth[j + 1], t))
		c.spd.append(lerpf(r.speed[j], r.speed[j + 1], t))
		c.fill.append(smoothstep(0.0, 250.0, s))
		if t == 0.0:
			c.ris.append(r.riser[j])
		elif t == 1.0:
			c.ris.append(r.riser[j + 1])
		else:
			c.ris.append(lerpf(r.riser[j], r.riser[j + 1], t) if r.riser[j] >= 0.0 and r.riser[j + 1] >= 0.0 else -1.0)
	c.run = PackedFloat32Array([0.0])
	for k in range(1, c.count):
		c.run.append(c.run[k - 1] + Vector2(c.pts[k].x - c.pts[k - 1].x, c.pts[k].z - c.pts[k - 1].z).length())
	return c


## The water's half width at sample k (narrower as it thins in at its head).
func width(k: int) -> float:
	return hw[k] * sqrt(maxf(fill[k], 0.05))


## The across direction, from a tangent averaged over about a width, so tight
## bends don't fold the ribbon's inner edge over itself; round a fall (where
## fine[k] > 0), over just a couple of metres, so each of its cross-sections
## lies square across it. And the bends' curvature (over the usual width).
func frames(fine: PackedInt32Array) -> void:
	tans = PackedVector2Array()
	var wide := PackedVector2Array()
	for k in count:
		for pass_ in 2:
			var span := 2.0 if fine[k] > 0 and pass_ == 0 else maxf(hw[k] * 1.2, STEP)
			var wa := k
			while wa > 0 and run[k] - run[wa] < span:
				wa -= 1
			var wb := k
			while wb < count - 1 and run[wb] - run[k] < span:
				wb += 1
			var t := Vector2(pts[wb].x - pts[wa].x, pts[wb].z - pts[wa].z)
			if pass_ == 0:   # (packed arrays are values: appended to directly)
				tans.append(t.normalized() if t.length() > 0.01 else (tans[k - 1] if k > 0 else Vector2(0.0, 1.0)))
			else:
				wide.append(t.normalized() if t.length() > 0.01 else (wide[k - 1] if k > 0 else Vector2(0.0, 1.0)))
	bend = PackedFloat32Array()
	for k in count:
		var ka := maxi(k - 1, 0)
		var kb := mini(k + 1, count - 1)
		var ds := Vector2(pts[kb].x - pts[ka].x, pts[kb].z - pts[ka].z).length()
		bend.append(wide[ka].angle_to(wide[kb]) / maxf(ds, 0.01) if kb > ka else 0.0)


## Coming into its river (`main`'s points near its mouth: near_pts, near_hw),
## a tributary's water reaches further out over its banks, so the fork
## between the two channels is under water too.
func compute_spread(end: Vector3, near_pts: PackedVector3Array, near_hw: PackedFloat32Array, near_range: float) -> void:
	spread = PackedFloat32Array()
	spread.resize(count)
	for k in count:
		var gap_m := INF
		if Vector2(pts[k].x - end.x, pts[k].z - end.z).length() > near_range:
			continue   # (spread stays 0)
		for q in near_pts.size():
			gap_m = minf(gap_m, Vector2(near_pts[q].x - pts[k].x, near_pts[q].z - pts[k].z).length() - near_hw[q])
		spread[k] = 1.0 - smoothstep(hw[k], 2.0 * hw[k] + 20.0, gap_m)
