class_name RiverRibbons
extends RefCounted
## The rivers' water as ribbon meshes that follow each channel, built from the
## generated centrelines (WorldData.rivers). This is how big open-world games
## build rivers: the mesh's UVs run along the river (UV.x across, -1 at the
## left bank to 1 at the right; UV.y the distance downstream in metres), so
## the shader moves its ripples down the channel and they follow every bend.
## The ribbon reaches a little past each bank and dips under the ground there,
## so the ground cuts the shoreline. Cross-sections are close enough that a
## waterfall stays a sheer drop. The mesh's normals carry the downstream
## direction, sloping down over falls (the shader builds the real normals from
## it). Vertex colour carries the current (m/s, red / 8), the depth (green /
## 8), how much water there is (blue: thinning in at a river's head, and
## gone deep inside the river a tributary joins) and the half width (alpha,
## m / 128). CUSTOM0 carries the falls: how far down a fall's sheet the
## vertex is (m, -1 off the falls), that fall's height, and how far
## downstream of the last fall's foot it is (m). Over a fall the sheet leaves
## the lip level and curves down as falling water does (a parabola), its
## cross-sections close together so the curve is smooth.
## The smallest streams come first in the mesh and the trunk last:
## the water is drawn in that order, so where a tributary's mouth lies under
## its river's ribbon only the river shows, with its one current.

const STEP := 2.0          ## Distance between cross-sections (m).
const ACROSS := 9          ## Vertices across the ribbon.
const REACH := 1.5         ## The ribbon reaches this many half widths from the centre.
const FALL_STEP := 0.5     ## Cross-sections over a fall (m along the drop).
const FALL_SLOPE := 1.0    ## A reach dropping more than this per metre run is a fall.


static func build(rivers: Array[Dictionary]) -> ArrayMesh:
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
		_ribbon(r, rivers[int(r.joins)] if int(r.joins) >= 0 else {}, verts, uvs, cols, dirs, falls, idx)
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


static func _ribbon(r: Dictionary, main: Dictionary, verts: PackedVector3Array, uvs: PackedVector2Array,
		cols: PackedColorArray, dirs: PackedVector3Array, falls: PackedFloat32Array, idx: PackedInt32Array) -> void:
	var src: PackedVector3Array = r.points
	var hw_src: PackedFloat32Array = r.half_width
	var dep_src: PackedFloat32Array = r.depth
	var spd_src: PackedFloat32Array = r.speed
	var fill_src: PackedFloat32Array = r.get("fill", PackedFloat32Array())
	# resample along the centreline (Catmull-Rom, so it stays smooth): about
	# every STEP m, and every FALL_STEP m down a fall
	var arc := PackedFloat32Array([0.0])
	for k in range(1, src.size()):
		arc.append(arc[k - 1] + Vector2(src[k].x - src[k - 1].x, src[k].z - src[k - 1].z).length())
	var total := arc[arc.size() - 1]
	var samples: Array[Vector2] = []   # (segment, t)
	for jj in src.size() - 1:
		var run := arc[jj + 1] - arc[jj]
		var drop := src[jj].y - src[jj + 1].y
		var n := maxi(ceili(run / STEP), 1)
		if drop > FALL_SLOPE * maxf(run, 0.01):
			n = maxi(ceili(drop / FALL_STEP), n)
		for q in n:
			samples.append(Vector2(jj, float(q) / n))
	samples.append(Vector2(src.size() - 2, 1.0))
	var count := samples.size()
	var pts := PackedVector3Array()
	var hw := PackedFloat32Array()
	var dep := PackedFloat32Array()
	var spd := PackedFloat32Array()
	var fill := PackedFloat32Array()
	var fall := PackedFloat32Array()     # down the sheet (m), -1 off it
	var fall_h := PackedFloat32Array()   # that fall's height
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
		var drop := p1.y - p2.y
		if drop > FALL_SLOPE * maxf(arc[j + 1] - arc[j], 0.01):
			# over the lip and down: level at first, then ever steeper
			p.y = p1.y - drop * t * t
			fall.append(drop * t * t)
			fall_h.append(drop)
		else:
			fall.append(-1.0)
			fall_h.append(0.0)
		pts.append(p)
		hw.append(lerpf(hw_src[j], hw_src[j + 1], t))
		dep.append(lerpf(dep_src[j], dep_src[j + 1], t))
		spd.append(lerpf(spd_src[j], spd_src[j + 1], t))
		fill.append(lerpf(fill_src[j], fill_src[j + 1], t) if fill_src.size() == src.size() else smoothstep(0.0, 250.0, s))
	# a tributary's ribbon ends inside the river it joins (which is drawn
	# over it)
	var near_pts := PackedVector3Array()
	var near_hw := PackedFloat32Array()
	if not main.is_empty():
		var end := src[src.size() - 1]
		var mp: PackedVector3Array = main.points
		var mhw: PackedFloat32Array = main.half_width
		for k in mp.size():
			if Vector2(mp[k].x - end.x, mp[k].z - end.z).length() < mhw[k] * 6.0 + 80.0:
				near_pts.append(mp[k])
				near_hw.append(mhw[k])
	# the across direction, from a tangent averaged over about a width, so
	# tight bends don't fold the ribbon's inner edge over itself
	# how far each cross-section is above the next fall: near a fall's lip and
	# down it the ribbon keeps to the channel, not reaching out past the
	# gorge's walls over the drop
	var to_fall := PackedFloat32Array()
	to_fall.resize(count)
	var gap := 1e9
	for k in range(count - 1, -1, -1):
		if fall[k] >= 0.0:
			gap = 0.0
		elif k < count - 1:
			gap += Vector2(pts[k + 1].x - pts[k].x, pts[k + 1].z - pts[k].z).length()
		to_fall[k] = gap
	var base := verts.size()
	var along := 0.0
	var below := 1000.0   # m downstream of the last fall's foot
	for k in count:
		var win := maxi(int(hw[k] * 1.2 / STEP), 1)
		var a := pts[maxi(k - win, 0)]
		var b := pts[mini(k + win, count - 1)]
		var tan := Vector2(b.x - a.x, b.z - a.z).normalized()
		var nrm := Vector2(-tan.y, tan.x)
		# downstream in 3D: steeply down over a fall
		var pa := pts[maxi(k - 1, 0)]
		var pb := pts[mini(k + 1, count - 1)]
		var run := Vector2(pb.x - pa.x, pb.z - pa.z).length()
		var down := Vector3(tan.x * run, pb.y - pa.y, tan.y * run).normalized()
		if k > 0:
			along += pts[k].distance_to(pts[k - 1])
			below += Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length()
		if fall[k] >= 0.0:
			below = 0.0
		var w := hw[k] * sqrt(maxf(fill[k], 0.05))
		var reach := lerpf(1.05, REACH, smoothstep(0.5 * hw[k], 2.0 * hw[k] + 4.0, to_fall[k]))
		for q in ACROSS:
			var u := lerpf(-1.0, 1.0, float(q) / (ACROSS - 1))
			var off := nrm * u * w * reach
			# the surface is level across; past the bank it dips a little, so
			# the ground always covers the ribbon's edge
			var dip := maxf(0.0, absf(u) * reach - 1.25) * 0.6
			var v := Vector3(pts[k].x + off.x, pts[k].y - dip, pts[k].z + off.y)
			verts.append(v)
			uvs.append(Vector2(u * reach, along))
			cols.append(Color(spd[k] / 8.0, dep[k] / 8.0, fill[k] * _fade_in_main(v, near_pts, near_hw), w / 128.0))
			dirs.append(down)
			falls.append_array([fall[k], fall_h[k], minf(below, 1000.0), 0.0])
	for k in count - 1:
		for q in ACROSS - 1:
			var a := base + k * ACROSS + q
			var c := a + ACROSS
			idx.append_array([a, c, a + 1, a + 1, c, c + 1])


# 1 outside the joined river's water, falling to 0 well inside it.
static func _fade_in_main(v: Vector3, pts: PackedVector3Array, hw: PackedFloat32Array) -> float:
	var r := INF
	for k in pts.size():
		r = minf(r, Vector2(pts[k].x - v.x, pts[k].z - v.z).length() / hw[k])
	return smoothstep(0.5, 0.8, r)
