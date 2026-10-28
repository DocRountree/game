class_name MeanderSim
extends RefCounted
## Meanders grown by letting the river migrate across its floodplain, the
## classic kinematic model (Howard & Knutson 1984, as in Paris et al. 2023,
## "Authoring and Simulating Meandering Rivers"): every bit of channel moves
## toward its outer bank at a rate set by its own curvature and, more, by the
## curvature upstream of it (the current carries its push downstream). It
## starts from moderate bends of varying length and swing; they swell, lean
## downstream and wander down the valley until the river is as winding as
## real ones get (a random 1.7 to 2.6 times the valley's length). When a loop's neck closes up the river cuts through it and the
## loop is left behind as an oxbow lake; old courses the river has moved away
## from stay on the floodplain as meander scars. The channel stays within its
## floodplain, and narrow valleys (no floodplain) keep their rivers as they are.

const ITERATIONS := 90    ## At most; most rivers reach their winding sooner.
const STEP_FRACTION := 0.35   ## A point on the sharpest bend moves this much of a step per iteration.
const OMEGA := -1.0        ## Local curvature term.
const GAMMA := 2.5         ## Upstream curvature term.
const SNAPSHOTS := [0.5, 0.8]   ## Old courses kept at these fractions of the final winding.


## Migrates `river` (resampled, with "fp" per point) in place; returns the
## oxbows and scars it left behind.
static func run(river: Dictionary, rng: RandomNumberGenerator, arid: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var pts3: PackedVector3Array = river.points
	var dep: PackedFloat32Array = river.depth
	var hw: PackedFloat32Array = river.half_width
	var fp: PackedFloat32Array = river.fp
	var count := pts3.size()
	if count < 12:
		return out
	# where it may move: a floodplain several widths across
	var mob := PackedFloat32Array()
	var a := -1
	var b := -1
	for k in count:
		var v := smoothstep(2.5, 6.0, fp[k] / hw[k])
		if k < 3 or k > count - 4:
			v = 0.0
		mob.append(v)
		if v > 0.05:
			if a < 0:
				a = k
			b = k
	if a < 0 or b - a < 10:
		return out
	a = maxi(a - 2, 0)
	b = mini(b + 2, count - 1)
	# the valley axis (the original course) over that span
	var axis := PackedVector2Array()
	var au := PackedFloat32Array()
	var ahw := PackedFloat32Array()
	var abelt := PackedFloat32Array()
	var amob := PackedFloat32Array()
	for k in range(a, b + 1):
		axis.append(Vector2(pts3[k].x, pts3[k].z))
		au.append(0.0 if au.is_empty() else au[au.size() - 1] + axis[axis.size() - 1].distance_to(axis[axis.size() - 2]))
		ahw.append(hw[k])
		abelt.append(maxf(fp[k] - 1.5 * hw[k], 0.0))
		amob.append(mob[k])
	var total := au[au.size() - 1]
	var last := axis.size() - 2
	var hw_mid := ahw[ahw.size() / 2]
	if hw_mid < 9.0:
		return out   # little streams keep their courses
	var tang := PackedVector2Array()
	for k in axis.size() - 1:
		tang.append((axis[k + 1] - axis[k]).normalized())
	var ds := clampf(hw_mid * 1.3, 15.0, 60.0)
	# start: the axis, resampled, already swinging in moderate bends (about
	# 14 widths long), within the floodplain; the migration does the rest
	var p := PackedVector2Array()
	var u := PackedFloat32Array()
	var steps := maxi(int(total / ds), 4)
	var ph := PackedFloat32Array()
	for _q in 6:
		ph.append(rng.randf() * TAU)
	var phase := ph[0]
	for k in steps + 1:
		var uu := total * k / steps
		var f := _axis(axis, au, uu)
		var w := _lerp_at(au, ahw, uu)
		# no two bends alike: their length and swing wander along the river
		var x := uu / w
		var longer := 1.0 + 0.45 * sin(x / 37.0 + ph[1]) + 0.25 * sin(x / 13.0 + ph[2])
		var swing := 0.75 + 0.35 * sin(x / 29.0 + ph[3]) + 0.2 * sin(x / 11.0 + ph[4])
		if k > 0:
			phase += (total / steps) / (w * 4.5 * longer)
		var wig := (sin(phase) + 0.3 * sin(phase * 0.43 + ph[5])) * 2.5 * w * swing
		var belt := _lerp_at(au, abelt, uu)
		var mob_here := _lerp_at(au, amob, uu) * smoothstep(0.0, 10.0 * w, uu) * smoothstep(0.0, 10.0 * w, total - uu)
		p.append(f[0] + f[2] * clampf(wig * mob_here, -belt * 0.6, belt * 0.6))
		u.append(uu)
	_resample(p, u, ds)
	var target := rng.randf_range(1.7, 2.6)   # how winding it ends up (length / valley length)
	var loops: Array[Dictionary] = []
	var snaps: Array[PackedVector2Array] = []
	var snap_u: Array[PackedFloat32Array] = []
	var c := PackedFloat32Array()
	var wv := PackedFloat32Array()
	var mv := PackedFloat32Array()
	var r := PackedFloat32Array()
	for it in ITERATIONS:
		var n := p.size()
		c.resize(n)
		wv.resize(n)
		mv.resize(n)
		r.resize(n)
		# the axis's width and mobility at each point
		for i in n:
			var k := clampi(au.bsearch(u[i]) - 1, 0, last)
			var t := clampf((u[i] - au[k]) / maxf(au[k + 1] - au[k], 1e-3), 0.0, 1.0)
			wv[i] = lerpf(ahw[k], ahw[k + 1], t)
			# (still at the ends: they meet the rest of the river, a junction or the sea)
			mv[i] = lerpf(amob[k], amob[k + 1], t) * smoothstep(0.0, 10.0 * wv[i], u[i]) \
					* smoothstep(0.0, 10.0 * wv[i], total - u[i])
		# curvature, lightly smoothed
		c[0] = 0.0
		c[n - 1] = 0.0
		for i in range(1, n - 1):
			var da := p[i] - p[i - 1]
			var db := p[i + 1] - p[i]
			c[i] = atan2(da.cross(db), da.dot(db)) / maxf((da.length() + db.length()) * 0.5, 0.1)
		for _s in 3:
			var prev := c[0]
			for i in range(1, n - 1):
				var cur := c[i]
				c[i] = (prev + cur * 2.0 + c[i + 1]) * 0.25
				prev = cur
		# migration rate: local curvature plus curvature upstream, fading
		# over a couple of channel widths (bends 10 to 15 widths long grow
		# fastest); scaled so the river keeps changing at a steady pace (a
		# typical fast bend moves a fraction of a step each iteration, and
		# no single kink sets the pace)
		var lag := 0.0
		for i in n:
			var decay := exp(-ds / (3.2 * wv[i]))
			if i > 0:
				lag = decay * (c[i - 1] + lag)
			r[i] = (OMEGA * c[i] + GAMMA * lag * (1.0 - decay) / decay) * mv[i]
		var mags := PackedFloat32Array()
		for i in range(0, n, 3):
			mags.append(absf(r[i]))
		mags.sort()
		var typical := mags[int(mags.size() * 0.9)]
		if typical < 1e-9:
			break
		for i in n:
			r[i] = clampf(r[i] / typical, -1.0, 1.0)
		for _s in 2:   # smooth the rates too: no wiggles shorter than a few steps
			var prev := r[0]
			for i in range(1, n - 1):
				var cur := r[i]
				r[i] = (prev + cur * 2.0 + r[i + 1]) * 0.25
				prev = cur
		for i in range(2, n - 2):
			if r[i] == 0.0:
				continue
			var tq := (p[i + 1] - p[i - 1]).normalized()
			var q := p[i] - Vector2(-tq.y, tq.x) * r[i] * STEP_FRACTION * ds   # toward the outer bank
			# stay on the floodplain: re-project onto the axis, limit the swing
			var k := clampi(au.bsearch(u[i]) - 1, 0, last)
			var t := clampf((u[i] - au[k]) / maxf(au[k + 1] - au[k], 1e-3), 0.0, 1.0)
			var ap := axis[k].lerp(axis[k + 1], t)
			var uu := u[i] + (q - ap).dot(tang[k])
			if uu <= 0.0 or uu >= total:
				continue
			k = clampi(au.bsearch(uu) - 1, 0, last)
			t = clampf((uu - au[k]) / maxf(au[k + 1] - au[k], 1e-3), 0.0, 1.0)
			ap = axis[k].lerp(axis[k + 1], t)
			var nrm := Vector2(-tang[k].y, tang[k].x)
			var belt := lerpf(abelt[k], abelt[k + 1], t)
			var side := (q - ap).dot(nrm)
			# bends slow down as they near the valley sides (round, not
			# squashed flat against them), and never cross them
			var was := absf((p[i] - ap).dot(nrm))
			if absf(side) > was and belt > 0.0:
				var room := clampf(1.0 - pow(was / belt, 2.0), 0.0, 1.0)
				side = signf(side) * (was + (absf(side) - was) * room)
			p[i] = ap + nrm * clampf(side, -belt, belt)
			u[i] = uu
		# where the channel doubles back on itself within a step or two (no
		# river turns that sharply), ease the kink out
		for i in range(1, p.size() - 1):
			var da := p[i] - p[i - 1]
			var db := p[i + 1] - p[i]
			if da.dot(db) < 0.2 * da.length() * db.length():
				p[i] = p[i].lerp((p[i - 1] + p[i + 1]) * 0.5, 0.6)
		_resample(p, u, ds)
		if it % 5 == 4:
			_cutoff(p, u, au, ahw, ds, loops)
		# grown up: as winding as rivers get (old courses kept on the way)
		var sinuosity := p.size() * ds / total
		if snaps.size() < SNAPSHOTS.size() and sinuosity > 1.0 + (target - 1.0) * SNAPSHOTS[snaps.size()]:
			snaps.append(p.duplicate())
			snap_u.append(u.duplicate())
		if sinuosity >= target:
			break
	# the new course, with everything else carried over from the old one at
	# the same distance down the valley
	var new_pts := PackedVector3Array()
	var fields := ["half_width", "depth", "flow", "speed", "fp"]
	var out_f := {}
	for fname in fields:
		out_f[fname] = PackedFloat32Array()
	var out_wet := PackedByteArray()
	var surf := PackedFloat32Array()
	for k in a:
		_copy_point(river, k, fields, new_pts, out_f, out_wet, surf)
	for i in p.size():
		var kf := a + _index_at(au, u[i])
		var k0 := mini(int(kf), count - 2)
		var f := kf - k0
		new_pts.append(Vector3(p[i].x, 0.0, p[i].y))
		surf.append(lerpf(pts3[k0].y, pts3[k0 + 1].y, f))
		for fname in fields:
			var src: PackedFloat32Array = river[fname]
			out_f[fname].append(lerpf(src[k0], src[k0 + 1], f))
		out_wet.append(river.wet[k0 + (1 if f > 0.5 else 0)])
	for k in range(b + 1, count):
		_copy_point(river, k, fields, new_pts, out_f, out_wet, surf)
	for i in new_pts.size():
		if i > 0:
			surf[i] = minf(surf[i], surf[i - 1])   # always downhill
		new_pts[i].y = surf[i]
	river.points = new_pts
	for fname in fields:
		river[fname] = out_f[fname]
	river.wet = out_wet
	# what it left behind, clear of today's channel
	var clear := _Clearance.new(p, ds * 2.0)
	for lp: Dictionary in loops:
		var w := _lerp_at(au, ahw, lp.u[lp.u.size() / 2])
		var kept := _clear_runs(lp.p, lp.u, clear, 2.4 * w)
		for run: Array in kept:
			var ox: bool = rng.randf() < 0.65 * (1.0 - arid)
			out.append(_relic(run[0], run[1], pts3, dep, a, au, ahw, ox))
	for s in snaps.size():
		for run: Array in _clear_runs(snaps[s], snap_u[s], clear, 2.8 * hw_mid):
			if run[0].size() >= 10:
				out.append(_relic(run[0], run[1], pts3, dep, a, au, ahw, false))
	return out


static func _copy_point(river: Dictionary, k: int, fields: Array, pts: PackedVector3Array,
		out_f: Dictionary, out_wet: PackedByteArray, surf: PackedFloat32Array) -> void:
	var src: PackedVector3Array = river.points
	pts.append(src[k])
	surf.append(src[k].y)
	for fname in fields:
		out_f[fname].append(river[fname][k])
	out_wet.append(river.wet[k])


# Axis point, tangent and left normal at distance uu along it.
static func _axis(axis: PackedVector2Array, au: PackedFloat32Array, uu: float) -> Array:
	var k := clampi(au.bsearch(uu) - 1, 0, axis.size() - 2)
	var seg := axis[k + 1] - axis[k]
	var t := clampf((uu - au[k]) / maxf(au[k + 1] - au[k], 1e-3), 0.0, 1.0)
	var tan := seg.normalized()
	return [axis[k] + seg * t, tan, Vector2(-tan.y, tan.x)]


static func _lerp_at(au: PackedFloat32Array, v: PackedFloat32Array, uu: float) -> float:
	var k := clampi(au.bsearch(uu) - 1, 0, au.size() - 2)
	var t := clampf((uu - au[k]) / maxf(au[k + 1] - au[k], 1e-3), 0.0, 1.0)
	return lerpf(v[k], v[k + 1], t)


static func _index_at(au: PackedFloat32Array, uu: float) -> float:
	var k := clampi(au.bsearch(uu) - 1, 0, au.size() - 2)
	return k + clampf((uu - au[k]) / maxf(au[k + 1] - au[k], 1e-3), 0.0, 1.0)


# Keep the points about ds apart: split long steps, merge short ones.
static func _resample(p: PackedVector2Array, u: PackedFloat32Array, ds: float) -> void:
	var np := PackedVector2Array([p[0]])
	var nu := PackedFloat32Array([u[0]])
	for i in range(1, p.size()):
		var last := np[np.size() - 1]
		var d := last.distance_to(p[i])
		if d < ds * 0.45 and i < p.size() - 1:
			continue
		if d > ds * 1.6:
			np.append((last + p[i]) * 0.5)
			nu.append((nu[nu.size() - 1] + u[i]) * 0.5)
		np.append(p[i])
		nu.append(u[i])
	p.resize(np.size())
	u.resize(nu.size())
	for i in np.size():
		p[i] = np[i]
		u[i] = nu[i]


# Where a loop's neck has closed (two parts of the channel, far apart along
# it, now touching), the river cuts straight through; the loop is left.
static func _cutoff(p: PackedVector2Array, u: PackedFloat32Array, au: PackedFloat32Array,
		ahw: PackedFloat32Array, ds: float, loops: Array[Dictionary]) -> void:
	var cellsz := ds * 3.0
	var grid := {}
	for i in p.size():
		var key := Vector2i(floori(p[i].x / cellsz), floori(p[i].y / cellsz))
		if grid.has(key):
			grid[key].append(i)
		else:
			grid[key] = PackedInt32Array([i])
	for i in p.size():
		var w := _lerp_at(au, ahw, u[i])
		var gap := maxi(ceili(7.0 * w / ds), 6)
		var reach := 2.2 * w
		var key := Vector2i(floori(p[i].x / cellsz), floori(p[i].y / cellsz))
		var span := ceili(reach / cellsz)
		for y in range(key.y - span, key.y + span + 1):
			for x in range(key.x - span, key.x + span + 1):
				var bucket: PackedInt32Array = grid.get(Vector2i(x, y), PackedInt32Array())
				for j in bucket:
					if j > i + gap and p[i].distance_to(p[j]) < reach:
						var lp := PackedVector2Array()
						var lu := PackedFloat32Array()
						for k in range(i, j + 1):
							lp.append(p[k])
							lu.append(u[k])
						loops.append({"p": lp, "u": lu})
						var np := p.slice(0, i + 1)
						np.append_array(p.slice(j))
						var nu := u.slice(0, i + 1)
						nu.append_array(u.slice(j))
						p.resize(np.size())
						u.resize(nu.size())
						for k in np.size():
							p[k] = np[k]
							u[k] = nu[k]
						return


# Runs of a polyline that stay clear of the channel.
static func _clear_runs(p: PackedVector2Array, u: PackedFloat32Array, clear: _Clearance, gap: float) -> Array:
	var runs := []
	var cur := PackedVector2Array()
	var cu := PackedFloat32Array()
	for i in p.size():
		if clear.near(p[i], gap):
			if cur.size() >= 6:
				runs.append([cur, cu])
			cur = PackedVector2Array()
			cu = PackedFloat32Array()
		else:
			cur.append(p[i])
			cu.append(u[i])
	if cur.size() >= 6:
		runs.append([cur, cu])
	return runs


# An old course: an oxbow lake (still water, almost as deep as the river) or
# a shallow dry scar, tapering at both ends where it silted up.
static func _relic(lp: PackedVector2Array, lu: PackedFloat32Array, src: PackedVector3Array,
		dep: PackedFloat32Array, a: int, au: PackedFloat32Array, ahw: PackedFloat32Array, oxbow: bool) -> Dictionary:
	var pts := PackedVector3Array()
	var shw := PackedFloat32Array()
	var sd := PackedFloat32Array()
	var level := INF
	for i in lp.size():
		var k := mini(a + int(_index_at(au, lu[i])), src.size() - 1)
		level = minf(level, src[k].y)
	if oxbow:
		level -= 0.3
	for i in lp.size():
		var t := float(i) / float(lp.size() - 1)
		var taper := sqrt(sin(PI * t))
		var w := _lerp_at(au, ahw, lu[i])
		var k := mini(a + int(_index_at(au, lu[i])), dep.size() - 1)
		pts.append(Vector3(lp[i].x, level, lp[i].y))
		shw.append(w * (0.85 if oxbow else 0.7) * taper + 0.5)
		sd.append(dep[k] * (0.8 if oxbow else 0.35) * taper)
	var zero := PackedFloat32Array()
	zero.resize(pts.size())
	var wet := PackedByteArray()
	wet.resize(pts.size())
	wet.fill(1 if oxbow else 0)
	return {"points": pts, "half_width": shw, "depth": sd, "speed": zero, "wet": wet,
			"flow": zero, "kind": WorldBake.OXBOW if oxbow else WorldBake.SCAR, "joins": -1}


# Points of today's channel in buckets, for "is this near the channel?".
class _Clearance:
	var grid := {}
	var cellsz := 1.0

	func _init(p: PackedVector2Array, size: float) -> void:
		cellsz = size
		for q in p:
			var key := Vector2i(floori(q.x / cellsz), floori(q.y / cellsz))
			if grid.has(key):
				grid[key].append(q)
			else:
				grid[key] = PackedVector2Array([q])

	func near(q: Vector2, r: float) -> bool:
		var key := Vector2i(floori(q.x / cellsz), floori(q.y / cellsz))
		var span := ceili(r / cellsz)
		var r2 := r * r
		for y in range(key.y - span, key.y + span + 1):
			for x in range(key.x - span, key.x + span + 1):
				for c: Vector2 in grid.get(Vector2i(x, y), PackedVector2Array()):
					if c.distance_squared_to(q) < r2:
						return true
		return false
