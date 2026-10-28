class_name RiverRibbons
extends RefCounted
## The rivers' water as ribbon meshes that follow each channel, built from the
## baked centrelines (WorldMaps.rivers). This is how big open-world games
## build rivers: the mesh's UVs run along the river (UV.x across, -1 at the
## left bank to 1 at the right; UV.y the distance downstream in metres), so
## the shader moves its ripples down the channel and they follow every bend.
## Rivers come from WorldData.rivers.
## The ribbon reaches a little past each bank and dips under the ground there,
## so the ground cuts the shoreline. The mesh's normals carry the downstream
## direction (the shader sets the real normals). Vertex colour carries the current (m/s,
## red / 8), the depth (green / 8) and how much the water thins in at a
## river's head and where it runs into another (blue: 0..1) and the half width
## (alpha, m / 64).

const STEP := 8.0          ## Distance between cross-sections (m).
const ACROSS := 9          ## Vertices across the ribbon.
const REACH := 1.5         ## The ribbon reaches this many half widths from the centre.


static func build(rivers: Array[Dictionary]) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var dirs := PackedVector3Array()
	var idx := PackedInt32Array()
	for ri in rivers.size():
		var r: Dictionary = rivers[ri]
		if r.points.size() < 2:
			continue
		var joins_hw := 0.0
		if int(r.joins) >= 0:
			var main: Dictionary = rivers[int(r.joins)]
			joins_hw = _hw_near(main, r.points[r.points.size() - 1])
		_ribbon(r, joins_hw, verts, uvs, cols, dirs, idx)
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_NORMAL] = dirs   # (not a normal: the downstream direction, read by the shader)
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _ribbon(r: Dictionary, joins_hw: float, verts: PackedVector3Array, uvs: PackedVector2Array,
		cols: PackedColorArray, dirs: PackedVector3Array, idx: PackedInt32Array) -> void:
	var src: PackedVector3Array = r.points
	var hw_src: PackedFloat32Array = r.half_width
	var dep_src: PackedFloat32Array = r.depth
	var spd_src: PackedFloat32Array = r.speed
	var fill_src: PackedFloat32Array = r.get("fill", PackedFloat32Array())
	# resample evenly along the centreline (Catmull-Rom, so it stays smooth)
	var arc := PackedFloat32Array([0.0])
	for k in range(1, src.size()):
		arc.append(arc[k - 1] + Vector2(src[k].x - src[k - 1].x, src[k].z - src[k - 1].z).length())
	var total := arc[arc.size() - 1]
	var count := maxi(int(total / STEP), 1) + 1
	var pts := PackedVector3Array()
	var hw := PackedFloat32Array()
	var dep := PackedFloat32Array()
	var spd := PackedFloat32Array()
	var fill := PackedFloat32Array()
	var j := 0
	for k in count:
		var s := total * k / (count - 1)
		while j < arc.size() - 2 and arc[j + 1] < s:
			j += 1
		var t := clampf((s - arc[j]) / maxf(arc[j + 1] - arc[j], 1e-3), 0.0, 1.0)
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
	# where a tributary runs into the river it joins, it fades out over the
	# last stretch, inside the bigger river's water
	if joins_hw > 0.0:
		for k in count:
			var to_end := total * (1.0 - float(k) / (count - 1))
			fill[k] = minf(fill[k], smoothstep(joins_hw * 0.6, joins_hw * 1.6, to_end) * 0.85 + 0.15)
	# the across direction, from a tangent averaged over about a width, so
	# tight bends don't fold the ribbon's inner edge over itself
	var base := verts.size()
	var along := 0.0
	for k in count:
		var win := maxi(int(hw[k] * 1.2 / STEP), 1)
		var a := pts[maxi(k - win, 0)]
		var b := pts[mini(k + win, count - 1)]
		var tan := Vector2(b.x - a.x, b.z - a.z).normalized()
		var nrm := Vector2(-tan.y, tan.x)
		if k > 0:
			along += Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length()
		var w := hw[k] * sqrt(maxf(fill[k], 0.05))
		for q in ACROSS:
			var u := lerpf(-1.0, 1.0, float(q) / (ACROSS - 1))
			var off := nrm * u * w * REACH
			# the surface is level across; past the bank it dips a little, so
			# the ground always covers the ribbon's edge
			var dip := maxf(0.0, absf(u) * REACH - 1.1) * 0.6
			verts.append(Vector3(pts[k].x + off.x, pts[k].y - dip, pts[k].z + off.y))
			uvs.append(Vector2(u * REACH, along))
			cols.append(Color(spd[k] / 8.0, dep[k] / 8.0, fill[k], w / 64.0))
			dirs.append(Vector3(tan.x, 0.0, tan.y))
	for k in count - 1:
		for q in ACROSS - 1:
			var a := base + k * ACROSS + q
			var c := a + ACROSS
			idx.append_array([a, c, a + 1, a + 1, c, c + 1])


static func _hw_near(river: Dictionary, p: Vector3) -> float:
	var pts: PackedVector3Array = river.points
	var hw: PackedFloat32Array = river.half_width
	var best := INF
	var out := 0.0
	for k in pts.size():
		var d := Vector2(pts[k].x - p.x, pts[k].z - p.z).length_squared()
		if d < best:
			best = d
			out = hw[k]
	return out
