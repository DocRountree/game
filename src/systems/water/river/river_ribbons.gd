class_name RiverRibbons
extends RefCounted
## The rivers' water as ribbon meshes that follow each channel, built from the
## generated centrelines (WorldData.rivers). This is how big open-world games
## build rivers: the mesh's UVs run along the river (UV.x across, -1 at the
## left bank to 1 at the right; UV.y the distance downstream in metres), so
## the shader moves its ripples down the channel and they follow every bend.
## The ribbon reaches a little past each bank and dips under the ground there,
## so the ground cuts the shoreline. The mesh's normals carry the downstream
## direction, steep down a waterfall (the shader builds the real normals from
## it). Vertex colour carries the current (m/s, red / 8), the depth (green /
## 8), how much water there is (blue: thinning in at a river's head, and
## gone deep inside the river a tributary joins) and the half width (alpha,
## m / 128). CUSTOM0 carries the falls: how far down a riser the vertex is
## (m, -1 off them), that riser's height, how far downstream of the last
## riser's foot it is and how far above the next riser's lip (m).
## Waterfalls are cascades the generator cut into the ground, a few steep
## risers with ledge pools between: on a ledge the water lies level, and down
## a riser it lies on the rock, a film over the ground exactly as the terrain
## draws it (WorldData.surface_at), its cross-sections about a metre apart
## each way so it follows the rock closely. It never rises above the level of
## the water at that point by more than a little (the banks stand higher), so
## it can't spill out over the banks, nor below the pool it falls into.
## The smallest streams come first in the mesh and the trunk last:
## the water is drawn in that order, so where a tributary's mouth lies under
## its river's ribbon only the river shows, with its one current.

const STEP := 2.0          ## Distance between cross-sections (m).
const ACROSS := 9          ## Vertices across the ribbon.
const ACROSS_FINE := 25    ## At most this many across it round a riser (about a metre apart).
const FINE_MARGIN := 3.0   ## The fine cross-sections reach this far either side of a riser (m).
const REACH := 1.5         ## The ribbon reaches this many half widths from the centre.
const FILM := 0.45         ## The water's thickness down a riser (m), over the rock under each vertex.
const FILM_MIN := 0.2      ## And at least this, over the rock between vertices.


static func build(rivers: Array[Dictionary], world: WorldData = null) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var dirs := PackedVector3Array()
	var falls := PackedFloat32Array()
	var idx := PackedInt32Array()
	for ri in range(rivers.size() - 1, -1, -1):
		var r: Dictionary = rivers[ri]
		if r.points.size() < 2:
			continue
		_ribbon(r, rivers[int(r.joins)] if int(r.joins) >= 0 else {}, world, verts, uvs, cols, dirs, falls, idx)
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_NORMAL] = dirs   # (not a normal: the downstream direction, read by the shader)
	arrays[Mesh.ARRAY_CUSTOM0] = falls
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh


static func _ribbon(r: Dictionary, main: Dictionary, world: WorldData, verts: PackedVector3Array, uvs: PackedVector2Array,
		cols: PackedColorArray, dirs: PackedVector3Array, falls: PackedFloat32Array, idx: PackedInt32Array) -> void:
	var src: PackedVector3Array = r.points
	var hw_src: PackedFloat32Array = r.half_width
	var dep_src: PackedFloat32Array = r.depth
	var spd_src: PackedFloat32Array = r.speed
	var fill_src: PackedFloat32Array = r.get("fill", PackedFloat32Array())
	var ris_src: PackedFloat32Array = r.get("riser", PackedFloat32Array())
	if ris_src.size() != src.size():
		ris_src.resize(src.size())
		ris_src.fill(-1.0)
	# resample along the centreline (Catmull-Rom, so it stays smooth): about
	# every STEP m (a cascade's points, closer than that, are kept as they are)
	var arc := PackedFloat32Array([0.0])
	for k in range(1, src.size()):
		arc.append(arc[k - 1] + Vector2(src[k].x - src[k - 1].x, src[k].z - src[k - 1].z).length())
	var samples: Array[Vector2] = []   # (segment, t)
	for jj in src.size() - 1:
		var n := maxi(ceili((arc[jj + 1] - arc[jj]) / STEP), 1)
		for q in n:
			samples.append(Vector2(jj, float(q) / n))
	samples.append(Vector2(src.size() - 2, 1.0))
	var count := samples.size()
	var pts := PackedVector3Array()
	var hw := PackedFloat32Array()
	var dep := PackedFloat32Array()
	var spd := PackedFloat32Array()
	var fill := PackedFloat32Array()
	var ris := PackedFloat32Array()
	for k in count:
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
		pts.append(p)
		hw.append(lerpf(hw_src[j], hw_src[j + 1], t))
		dep.append(lerpf(dep_src[j], dep_src[j + 1], t))
		spd.append(lerpf(spd_src[j], spd_src[j + 1], t))
		fill.append(lerpf(fill_src[j], fill_src[j + 1], t) if fill_src.size() == src.size() else smoothstep(0.0, 250.0, s))
		if t == 0.0:
			ris.append(ris_src[j])
		elif t == 1.0:
			ris.append(ris_src[j + 1])
		else:
			ris.append(lerpf(ris_src[j], ris_src[j + 1], t) if ris_src[j] >= 0.0 and ris_src[j + 1] >= 0.0 else -1.0)
	var ground_run := PackedFloat32Array([0.0])
	for k in range(1, count):
		ground_run.append(ground_run[k - 1] + Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length())
	# the risers: each one's lip (its top) and pool (its floor) levels; how far
	# down one each cross-section is, its height (carried on below it), how
	# far below the last one's foot and above the next one's lip
	var sheet := PackedFloat32Array()
	var top := PackedFloat32Array()
	var floor_ := PackedFloat32Array()
	var fall_h := PackedFloat32Array()
	sheet.resize(count)
	top.resize(count)
	floor_.resize(count)
	fall_h.resize(count)
	var k0 := 0
	var last_h := 0.0
	while k0 < count:
		if ris[k0] < 0.0:
			sheet[k0] = -1.0
			fall_h[k0] = last_h
			top[k0] = pts[k0].y
			floor_[k0] = pts[k0].y
			k0 += 1
			continue
		var k1 := k0
		while k1 + 1 < count and ris[k1 + 1] >= 0.0:
			k1 += 1
		last_h = pts[k0].y - pts[k1].y
		for k in range(k0, k1 + 1):
			sheet[k] = pts[k0].y - pts[k].y
			top[k] = pts[k0].y
			floor_[k] = pts[k1].y
			fall_h[k] = last_h
		k0 = k1 + 1
	var below := PackedFloat32Array()
	var to_fall := PackedFloat32Array()
	var spill := PackedFloat32Array()   # just below a riser: how high the water may lie over the rock at its foot (else -INF)
	below.resize(count)
	to_fall.resize(count)
	spill.resize(count)
	var gap := 1000.0
	var last_top := -INF
	for k in count:
		if sheet[k] >= 0.0:
			gap = 0.0
			last_top = top[k]
		elif k > 0:
			gap += ground_run[k] - ground_run[k - 1]
		below[k] = gap
		# (up to 1.5 m, less the further below the foot)
		spill[k] = -INF
		if sheet[k] < 0.0 and gap < FINE_MARGIN:
			spill[k] = pts[k].y + minf(last_top - pts[k].y, 1.5) * (1.0 - smoothstep(0.0, FINE_MARGIN, gap))
	gap = 1000.0
	for k in range(count - 1, -1, -1):
		if sheet[k] >= 0.0:
			gap = 0.0
		elif k < count - 1:
			gap += ground_run[k + 1] - ground_run[k]
		to_fall[k] = gap
	# round each riser (and a little either side) the cross-sections are
	# fine: about a metre apart across (as many as the widest of them needs)
	var fine := PackedInt32Array()
	fine.resize(count)
	var k2 := 0
	while k2 < count:
		if minf(below[k2], to_fall[k2]) >= FINE_MARGIN:
			fine[k2] = 0
			k2 += 1
			continue
		var k3 := k2
		var widest := 0.0
		while k3 < count and minf(below[k3], to_fall[k3]) < FINE_MARGIN:
			widest = maxf(widest, hw[k3])
			k3 += 1
		var nf := clampi(2 * ceili(1.05 * widest) + 1, ACROSS, ACROSS_FINE)
		for k in range(k2, k3):
			fine[k] = nf
		k2 = k3
	# a tributary's ribbon ends inside the river it joins (which is drawn
	# over it)
	var near_pts := PackedVector3Array()
	var near_hw := PackedFloat32Array()
	var end := src[src.size() - 1]
	var near_range := 0.0
	if not main.is_empty():
		var mp: PackedVector3Array = main.points
		var mhw: PackedFloat32Array = main.half_width
		for k in mp.size():
			if Vector2(mp[k].x - end.x, mp[k].z - end.z).length() < mhw[k] * 6.0 + 80.0:
				near_pts.append(mp[k])
				near_hw.append(mhw[k])
				near_range = maxf(near_range, mhw[k] * 7.0 + 100.0)
	# coming into its river, a tributary's water reaches further out over its
	# banks, so the fork between the two channels is under water too
	var spread := PackedFloat32Array()
	spread.resize(count)
	for k in count:
		var gap_m := INF
		if Vector2(pts[k].x - end.x, pts[k].z - end.z).length() > near_range:
			continue   # (spread stays 0)
		for q in near_pts.size():
			gap_m = minf(gap_m, Vector2(near_pts[q].x - pts[k].x, near_pts[q].z - pts[k].z).length() - near_hw[q])
		spread[k] = 1.0 - smoothstep(hw[k], 2.0 * hw[k] + 20.0, gap_m)
	# the across direction, from a tangent averaged over about a width, so
	# tight bends don't fold the ribbon's inner edge over itself; and on the
	# inside of a bend the ribbon reaches no further than most of the way to
	# the bend's centre (where a wide mouth bends, it would overlap itself)
	# (round a riser, over just a couple of metres: the steps are set off to
	# one side and the other, and each one's cross-sections must lie square
	# across it)
	var tans := PackedVector2Array()
	var wide := PackedVector2Array()   # (over the usual width, for the bends)
	for k in count:
		for pass_ in 2:
			var span := 2.0 if fine[k] > 0 and pass_ == 0 else maxf(hw[k] * 1.2, STEP)
			var wa := k
			while wa > 0 and ground_run[k] - ground_run[wa] < span:
				wa -= 1
			var wb := k
			while wb < count - 1 and ground_run[wb] - ground_run[k] < span:
				wb += 1
			var t := Vector2(pts[wb].x - pts[wa].x, pts[wb].z - pts[wa].z)
			if pass_ == 0:   # (packed arrays are values: appended to directly)
				tans.append(t.normalized() if t.length() > 0.01 else (tans[k - 1] if k > 0 else Vector2(0.0, 1.0)))
			else:
				wide.append(t.normalized() if t.length() > 0.01 else (wide[k - 1] if k > 0 else Vector2(0.0, 1.0)))
	var bend := PackedFloat32Array()   # signed curvature (1/m), + turning left
	for k in count:
		var ka := maxi(k - 1, 0)
		var kb := mini(k + 1, count - 1)
		var ds := Vector2(pts[kb].x - pts[ka].x, pts[kb].z - pts[ka].z).length()
		bend.append(wide[ka].angle_to(wide[kb]) / maxf(ds, 0.01) if kb > ka else 0.0)
	# every cross-section's vertices (and, where the next has a different
	# number of them, a copy of it with that many, so the two meet edge to edge)
	var rows: Array[PackedVector3Array] = []
	var row_x: Array[PackedFloat32Array] = []
	var row_lo: Array[PackedFloat32Array] = []
	var row_hi: Array[PackedFloat32Array] = []
	var row_k := PackedInt32Array()
	for k in count:
		var n_here := fine[k] if fine[k] > 0 else ACROSS
		for kk in ([k - 1, k] if k > 0 and rows[rows.size() - 1].size() != n_here else [k]):
			var xs := PackedFloat32Array()
			var lo := PackedFloat32Array()
			var hi := PackedFloat32Array()
			rows.append(_section(kk, n_here, pts, hw, dep, fill, tans, bend, sheet, top, floor_, to_fall, spill, spread, world, xs, lo, hi))
			row_x.append(xs)
			row_lo.append(lo)
			row_hi.append(hi)
			row_k.append(kk)
	# where the water lies on the rock: wherever the rock between two
	# neighbouring vertices (across, down, and along each triangle's
	# diagonal) would come through the water, both are lifted clear of it;
	# then each is held to its bounds again (its lip, its pool, the banks)
	if world:
		for it in 2:
			for ri in rows.size():
				if row_lo[ri].is_empty():
					continue
				var a := rows[ri]
				var n := a.size()
				var nxt := ri + 1 < rows.size() and not row_lo[ri + 1].is_empty() and rows[ri + 1].size() == n and row_k[ri + 1] != row_k[ri]
				var b := rows[ri + 1] if nxt else PackedVector3Array()
				for q in n:
					var inner_q := absf(row_x[ri][q]) < 0.85
					if q + 1 < n and inner_q and absf(row_x[ri][q + 1]) < 0.85:
						var m := (a[q] + a[q + 1]) * 0.5
						var lift := world.surface_at(m.x, m.z) + FILM_MIN - m.y
						if lift > 0.0:
							a[q].y += lift
							a[q + 1].y += lift
					if nxt and inner_q:
						var m := (a[q] + b[q]) * 0.5
						var lift := world.surface_at(m.x, m.z) + FILM_MIN - m.y
						if lift > 0.0:
							a[q].y += lift
							b[q].y += lift
						if q + 1 < n and absf(row_x[ri][q + 1]) < 0.85:
							m = (b[q] + a[q + 1]) * 0.5
							lift = world.surface_at(m.x, m.z) + FILM_MIN - m.y
							if lift > 0.0:
								b[q].y += lift
								a[q + 1].y += lift
				rows[ri] = a
				if nxt:
					rows[ri + 1] = b
		for ri in rows.size():
			if row_lo[ri].is_empty():
				continue
			var a := rows[ri]
			for q in a.size():
				a[q].y = clampf(a[q].y, row_lo[ri][q], row_hi[ri][q])
			rows[ri] = a
	var base := verts.size()
	var along := 0.0
	for ri in rows.size():
		var k := row_k[ri]
		var row := rows[ri]
		var n := row.size()
		if ri > 0 and row_k[ri - 1] != k:
			along += _at(rows[ri], 0.5).distance_to(_at(rows[ri - 1], 0.5))
		var w := hw[k] * sqrt(maxf(fill[k], 0.05))
		# the neighbouring cross-sections, for the direction downstream
		var ra := ri - 1
		while ra > 0 and row_k[ra] == k:
			ra -= 1
		var rb := ri + 1
		while rb < rows.size() - 1 and row_k[rb] == k:
			rb += 1
		ra = maxi(ra, 0)
		rb = mini(rb, rows.size() - 1)
		for q in n:
			var u := float(q) / (n - 1)
			var v := row[q]
			var down := _at(rows[rb], 0.5) - _at(rows[ra], 0.5)   # (the slope down the middle: steady across it)
			if down.length() < 0.001:
				down = Vector3(tans[k].x, 0.0, tans[k].y)
			var wet := 1.0
			if world and fine[k] == 0 and world.height_at(v.x, v.z) < v.y - dep[k] - 1.5:
				wet = 0.0   # (hanging out over the ground falling away: none there)
			var fade := 1.0
			if near_range > 0.0 and Vector2(v.x - end.x, v.z - end.z).length() < near_range:
				fade = _fade_in_main(v, near_pts, near_hw)
			verts.append(v)
			uvs.append(Vector2(row_x[ri][q], along))
			cols.append(Color(spd[k] / 8.0, dep[k] / 8.0, fill[k] * wet * fade, w / 128.0))
			dirs.append(down.normalized())
			falls.append_array([sheet[k], fall_h[k], minf(below[k], 1000.0), minf(to_fall[k], 1000.0)])
		if ri < rows.size() - 1 and rows[ri + 1].size() == n:
			var a := base
			for q in n - 1:
				idx.append_array([a + q, a + n + q, a + q + 1, a + q + 1, a + n + q, a + n + q + 1])
		base += n


# One cross-section's vertices (n of them, left bank to right): level across
# the channel, dipping a little past the banks; down a riser, lying on the
# rock; and just below one, over any of the rock at its foot that stands
# above the pool (the 2.5 m grid can't make the foot of a tall riser sharp:
# the water pours on over it). xs gets each vertex's distance from the
# centre in half widths.
static func _section(k: int, n: int, pts: PackedVector3Array, hw: PackedFloat32Array, dep: PackedFloat32Array,
		fill: PackedFloat32Array, tans: PackedVector2Array, bend: PackedFloat32Array, sheet: PackedFloat32Array,
		top: PackedFloat32Array, floor_: PackedFloat32Array, to_fall: PackedFloat32Array, spill: PackedFloat32Array,
		spread: PackedFloat32Array, world: WorldData, xs: PackedFloat32Array, lo: PackedFloat32Array,
		hi: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var tan := tans[k]
	var nrm := Vector2(-tan.y, tan.x)
	var w := hw[k] * sqrt(maxf(fill[k], 0.05))
	# near a fall's lip and down it the ribbon keeps to the channel, not
	# reaching out past the gorge's walls
	var reach := lerpf(1.05, REACH + 0.7 * spread[k], smoothstep(0.5 * hw[k], 2.0 * hw[k] + 4.0, to_fall[k]))
	if sheet[k] >= 0.0:
		reach = 1.05
	var inner := 0.8 / maxf(absf(bend[k]), 1e-6)
	for q in n:
		var u := lerpf(-1.0, 1.0, float(q) / (n - 1))
		var side := u * w * reach   # m across, + to the left
		if side * bend[k] > 0.0:
			side = signf(side) * minf(absf(side), inner)
		var off := nrm * side
		var x := side / maxf(w, 0.01)   # (half widths)
		# the surface is level across; past the bank it dips a little, so
		# the ground always covers the ribbon's edge
		var dip := maxf(0.0, absf(x) - 1.25) * 0.6
		var v := Vector3(pts[k].x + off.x, pts[k].y - dip, pts[k].z + off.y)
		if (sheet[k] >= 0.0 or spill[k] > -INF) and world:
			# (lo and hi: its bounds, held to again once the water has been
			# lifted clear of the rock between vertices)
			var g := world.surface_at(v.x, v.z)
			var ax := absf(x)
			if sheet[k] >= 0.0:
				# down a riser: a film on the rock, tucked under the ground at
				# its edges; never above its lip, nor below the pool it falls
				# into, and toward its edges never above the water's level there
				# (where the banks are: in the middle it pours over whatever
				# rock it meets)
				var film := FILM * (1.0 - smoothstep(0.7, 0.98, ax)) - 0.35 * smoothstep(0.9, 1.05, ax)
				var cap := 2.0 * (1.0 - smoothstep(0.6, 0.95, ax))
				lo.append(floor_[k])
				hi.append(minf(pts[k].y + cap, top[k]))
				v.y = clampf(g + film, lo[q], hi[q])
			else:
				# at its foot: level, but lifted over rock standing above it
				lo.append(v.y)
				hi.append(v.y + (spill[k] - v.y) * (1.0 - smoothstep(0.35, 0.6, ax)))   # (mid-channel: not up the walls beside it)
				v.y = clampf(g + FILM, lo[q], hi[q])
		out.append(v)
		xs.append(x)
	return out


# The point u (0..1, left to right) of the way across a cross-section.
static func _at(row: PackedVector3Array, u: float) -> Vector3:
	var f := u * (row.size() - 1)
	var i := mini(int(f), row.size() - 2)
	return row[i].lerp(row[i + 1], f - i)


# 1 outside the joined river's water, falling to 0 well inside it.
static func _fade_in_main(v: Vector3, pts: PackedVector3Array, hw: PackedFloat32Array) -> float:
	var r := INF
	for k in pts.size():
		r = minf(r, Vector2(pts[k].x - v.x, pts[k].z - v.z).length() / hw[k])
	return smoothstep(0.5, 0.8, r)
