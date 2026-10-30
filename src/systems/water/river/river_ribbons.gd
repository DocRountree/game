class_name RiverRibbons
extends RefCounted
## The rivers' water as ribbon meshes that follow each channel, built from the
## generated rivers (RiverData). This is how big open-world games
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
## Waterfalls are single steep drops the generator cut into the ground. Down
## each one's face the ribbon's cross-sections are about 0.4 m apart each way
## and the water comes down its stepped rock in separate streams (FallFace):
## the rock of the face is built here too, a relief standing out from the
## ground exactly as the terrain draws it (Terrain.surface_at) where the
## streams come down, sinking back under the ground out beside them (it
## carries the ground's normal, so it's shaded as the cliff round it is),
## and the water lies over it, leaving each
## ledge and falling to the next where one of the face's streams runs (the
## shader leaves the rock between them bare); just above the lip that rock
## rises out of the bed between the streams and stands above the water.
## CUSTOM1.x is the fall the vertex is on, just above or a little below (-1
## away from them; the faces' cells go to the shader as a texture), CUSTOM1.y
## how far down its face (m: negative above its lip, its height and more
## below its foot). Just below a fall the level water is
## lifted over any rock at its foot that stands above the pool.
##
## It is built in stages, each its own class: the centreline resampled with
## its frames (RibbonCentreline), the falls along it (RibbonFallSpans, each
## with its FallFace), the cross-sections (RibbonSections: how fine, laid
## out, settled on the rock), the falls' rock and landings (FallGeometry),
## and here the vertex attributes, river by river into one mesh.
## The smallest streams come first in the mesh and the trunk last:
## the water is drawn in that order, so where a tributary's mouth lies under
## its river's ribbon only the river shows, with its one current.


## Every river's water as one mesh; the falls' faces, rock and landings go
## into `geo`. Ground questions go to `ground` (none: the water lies level).
static func build(rivers: Array[RiverData], ground: TerrainSource = null, geo: FallGeometry = null) -> ArrayMesh:
	if geo == null:
		geo = FallGeometry.new()
	var out := Attributes.new()
	for ri in range(rivers.size() - 1, -1, -1):
		var r := rivers[ri]
		if r.points.size() < 2:
			continue
		_ribbon(r, rivers[r.joins] if r.joins >= 0 else null, ground, out, geo)
	return out.mesh()


## The water mesh's vertex attributes as they're built (see the top).
class Attributes:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var dirs := PackedVector3Array()
	var falls := PackedFloat32Array()
	var ids := PackedFloat32Array()
	var idx := PackedInt32Array()

	func mesh() -> ArrayMesh:
		var m := ArrayMesh.new()
		if verts.is_empty():
			return m
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = cols
		arrays[Mesh.ARRAY_NORMAL] = dirs   # (not a normal: the downstream direction, read by the shader)
		arrays[Mesh.ARRAY_CUSTOM0] = falls
		arrays[Mesh.ARRAY_CUSTOM1] = ids
		arrays[Mesh.ARRAY_INDEX] = idx
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
		return m


static func _ribbon(r: RiverData, main: RiverData, ground: TerrainSource, out: Attributes, geo: FallGeometry) -> void:
	var c := RibbonCentreline.resample(r)
	var f := RibbonFallSpans.find(c, geo)
	var fine := RibbonSections.resolution(c, f, geo)
	c.frames(fine)
	# a tributary's ribbon ends inside the river it joins (which is drawn
	# over it); coming into it, its water reaches further out over its banks
	var near_pts := PackedVector3Array()
	var near_hw := PackedFloat32Array()
	var end := r.mouth()
	var near_range := 0.0
	if main:
		for k in main.points.size():
			var mp := main.points[k]
			if Vector2(mp.x - end.x, mp.z - end.z).length() < main.half_width[k] * 6.0 + 80.0:
				near_pts.append(mp)
				near_hw.append(main.half_width[k])
				near_range = maxf(near_range, main.half_width[k] * 7.0 + 100.0)
	c.compute_spread(end, near_pts, near_hw, near_range)
	var sec := RibbonSections.build(c, f, geo, fine, ground)
	sec.settle(ground)
	# the vertices, row by row, with their attributes; and the rock of a
	# fall's face, row by row with its water
	var rows := sec.rows
	var base := out.verts.size()
	var along := 0.0
	for ri in rows.size():
		var k := sec.row_k[ri]
		var row := rows[ri]
		var n := row.size()
		if ri > 0 and sec.row_k[ri - 1] != k:
			along += RibbonSections.point_across(rows[ri], 0.5).distance_to(RibbonSections.point_across(rows[ri - 1], 0.5))
		var w := c.width(k)
		# the neighbouring cross-sections, for the direction downstream
		var ra := ri - 1
		while ra > 0 and sec.row_k[ra] == k:
			ra -= 1
		var rb := ri + 1
		while rb < rows.size() - 1 and sec.row_k[rb] == k:
			rb += 1
		ra = maxi(ra, 0)
		rb = mini(rb, rows.size() - 1)
		for q in n:
			var v := row[q]
			var down := RibbonSections.point_across(rows[rb], 0.5) - RibbonSections.point_across(rows[ra], 0.5)   # (the slope down the middle: steady across it)
			if down.length() < 0.001:
				down = Vector3(c.tans[k].x, 0.0, c.tans[k].y)
			if f.sheet[k] < 0.0:   # (off a fall the water runs level, even next to a lip: it doesn't start falling early)
				down.y = maxf(down.y, -0.15 * Vector2(down.x, down.z).length())
			var wet := 1.0
			if ground and fine[k] == 0 and ground.height_at(v.x, v.z) < v.y - c.dep[k] - 1.5:
				wet = 0.0   # (hanging out over the ground falling away: none there)
			var fade := 1.0
			if near_range > 0.0 and Vector2(v.x - end.x, v.z - end.z).length() < near_range:
				fade = _fade_in_main(v, near_pts, near_hw)
			out.verts.append(v)
			out.uvs.append(Vector2(sec.row_x[ri][q], along))
			out.cols.append(Color(c.spd[k] / 8.0, c.dep[k] / 8.0, c.fill[k] * wet * fade, w / 128.0))
			out.dirs.append(down.normalized())
			out.falls.append_array([f.sheet[k], f.fall_h[k], minf(f.below[k], 1000.0), minf(f.to_fall[k], 1000.0)])
			out.ids.append_array([f.near_of[k], f.near_d[k], 0.0, 0.0])
		if ri < rows.size() - 1 and rows[ri + 1].size() == n:
			var a := base
			for q in n - 1:
				out.idx.append_array([a + q, a + n + q, a + q + 1, a + q + 1, a + n + q, a + n + q + 1])
		base += n
		var rk := sec.row_rock[ri]
		if not rk.is_empty():
			var rf := f.face_at(k)
			var u_m := PackedFloat32Array()
			for q in rk.size():
				u_m.append(sec.row_x[ri][q] * w)
			var rb0 := geo.add_rock_row(rk, u_m, f.near_d[k], ground)
			var rn := ri + 1
			while rn < rows.size() and sec.row_rock[rn].is_empty() and sec.row_k[rn] == k:
				rn += 1
			if rn < rows.size() and sec.row_rock[rn].size() == rk.size() and f.near_of[sec.row_k[rn]] == rf:
				geo.join_rock_rows(rb0, rk.size())
	# where the streams land, for the splash
	for run in f.runs:
		geo.add_landings(c, f, run, ground)


# 1 outside the joined river's water, falling to 0 well inside it.
static func _fade_in_main(v: Vector3, pts: PackedVector3Array, hw: PackedFloat32Array) -> float:
	var r := INF
	for k in pts.size():
		r = minf(r, Vector2(pts[k].x - v.x, pts[k].z - v.z).length() / hw[k])
	return smoothstep(0.5, 0.8, r)
