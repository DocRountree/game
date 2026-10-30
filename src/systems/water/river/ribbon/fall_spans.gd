class_name RibbonFallSpans
extends RefCounted
## Stage 2 of a river's ribbon: its falls along the resampled centreline.
## Each run of samples down a fall's face gets a FallFace (its ledges and
## streams, added to the shared FallGeometry); per sample: how far down a
## face (`sheet`, -1 off them), that fall's lip and foot levels and height
## (carried on below it), how far below the last foot and above the next lip,
## how high the water may lie over rock just below a foot (`spill`), and
## which fall a sample is on, just above (`lip_of`) or a little below
## (`near_of`), with its signed distance down that face (`near_d`: negative
## above the lip, its height and more below the foot).

const FINE_MARGIN := 3.0   ## Fine cross-sections reach this far either side of a fall (m).
const FOOT_REACH := 40.0   ## Below a fall its streams' landing is followed this far (m, beyond 2 half widths).

var sheet := PackedFloat32Array()
var top := PackedFloat32Array()
var floor_ := PackedFloat32Array()
var fall_h := PackedFloat32Array()
var face_of := PackedInt32Array()
var runs: Array[Vector2i] = []
var below := PackedFloat32Array()
var to_fall := PackedFloat32Array()
var spill := PackedFloat32Array()
var lip_of := PackedInt32Array()
var near_of := PackedInt32Array()
var near_d := PackedFloat32Array()


static func find(c: RibbonCentreline, geo: FallGeometry) -> RibbonFallSpans:
	var f := RibbonFallSpans.new()
	var count := c.count
	var pts := c.pts
	f.sheet.resize(count)
	f.top.resize(count)
	f.floor_.resize(count)
	f.fall_h.resize(count)
	f.face_of.resize(count)
	f.face_of.fill(-1)
	var k0 := 0
	var last_h := 0.0
	while k0 < count:
		if c.ris[k0] < 0.0:
			f.sheet[k0] = -1.0
			f.fall_h[k0] = last_h
			f.top[k0] = pts[k0].y
			f.floor_[k0] = pts[k0].y
			k0 += 1
			continue
		var k1 := k0
		while k1 + 1 < count and c.ris[k1 + 1] >= 0.0:
			k1 += 1
		last_h = pts[k0].y - pts[k1].y
		var wf := 0.0
		for k in range(k0, k1 + 1):
			wf = maxf(wf, c.width(k))
		var face := FallFace.make(last_h, wf, int(pts[k0].x * 13.0 + pts[k0].z * 7.0))
		for k in range(k0, k1 + 1):
			f.sheet[k] = pts[k0].y - pts[k].y
			f.top[k] = pts[k0].y
			f.floor_[k] = pts[k1].y
			f.fall_h[k] = last_h
			f.face_of[k] = geo.faces.size()
		geo.faces.append(face)
		f.runs.append(Vector2i(k0, k1))
		k0 = k1 + 1
	f.below.resize(count)
	f.to_fall.resize(count)
	f.spill.resize(count)
	var gap := 1000.0
	var last_top := -INF
	for k in count:
		if f.sheet[k] >= 0.0:
			gap = 0.0
			last_top = f.top[k]
		elif k > 0:
			gap += c.run[k] - c.run[k - 1]
		f.below[k] = gap
		# (up to 1.5 m, less the further below the foot)
		f.spill[k] = -INF
		if f.sheet[k] < 0.0 and gap < FINE_MARGIN:
			f.spill[k] = pts[k].y + minf(last_top - pts[k].y, 1.5) * (1.0 - smoothstep(0.0, FINE_MARGIN, gap))
	gap = 1000.0
	for k in range(count - 1, -1, -1):
		if f.sheet[k] >= 0.0:
			gap = 0.0
		elif k < count - 1:
			gap += c.run[k + 1] - c.run[k]
		f.to_fall[k] = gap
	f.lip_of.resize(count)
	f.near_of.resize(count)
	f.near_d.resize(count)
	f.lip_of.fill(-1)
	f.near_of.fill(-1)
	for run in f.runs:
		var fi := f.face_of[run.x]
		var k := run.x - 1
		while k >= 0 and f.sheet[k] < 0.0 and c.run[run.x] - c.run[k] < FallFace.PRE:
			f.lip_of[k] = fi
			f.near_of[k] = fi
			f.near_d[k] = c.run[k] - c.run[run.x]
			k -= 1
		for kk in range(run.x, run.y + 1):
			f.near_of[kk] = fi
			f.near_d[kk] = f.sheet[kk]
		var reach_m := 2.0 * c.hw[run.y] + FOOT_REACH
		k = run.y + 1
		while k < count and f.sheet[k] < 0.0 and f.below[k] < reach_m:
			f.near_of[k] = fi
			f.near_d[k] = f.fall_h[k] + f.below[k]
			k += 1
	return f


## The face sample k lies on or just above (or -1).
func face_at(k: int) -> int:
	return face_of[k] if face_of[k] >= 0 else lip_of[k]
