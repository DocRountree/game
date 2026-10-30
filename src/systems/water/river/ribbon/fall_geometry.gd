class_name FallGeometry
extends RefCounted
## The waterfalls' faces, filled in as the rivers' ribbons are built
## (RiverRibbons): each fall's FallFace (its ledges and streams, for the
## shader's textures), the rock of the faces as one mesh (UV across and down
## the face in metres, negative above the lip; COLOR the ground's normal
## under it), and where their water lands, on a ledge or at the foot (for
## the splash, RiverSpray).

var faces: Array[FallFace] = []
var verts := PackedVector3Array()
var uvs := PackedVector2Array()
var cols := PackedColorArray()      ## (the ground's own normal under each vertex, as 0..1)
var idx := PackedInt32Array()
var ledges: Array = []              ## [position, downstream (Vector2), size]
var feet: Array = []                ## Where each stream lands at a fall's foot: [position, downstream (Vector2), the fall's height, the stream's half width]


## One row of a face's rock: its vertices (u_m: each one's distance across in
## m, d: how far down the face), joined to the previous row if `join`.
func add_rock_row(rock: PackedVector3Array, u_m: PackedFloat32Array, d: float, ground: TerrainSource) -> int:
	var base := verts.size()
	for q in rock.size():
		verts.append(rock[q])
		uvs.append(Vector2(u_m[q], d))
		var gn := ground.normal_at(rock[q].x, rock[q].z) if ground else Vector3.UP
		cols.append(Color(gn.x * 0.5 + 0.5, gn.y * 0.5 + 0.5, gn.z * 0.5 + 0.5))
	return base


## Join the rock row starting at `a` to the next one (both m vertices).
func join_rock_rows(a: int, m: int) -> void:
	for q in m - 1:
		idx.append_array([a + q, a + m + q, a + q + 1, a + q + 1, a + m + q, a + m + q + 1])


func rock_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# (smooth normals: the ledges are rounded rock, not facets)
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.generate_normals()
	return st.commit()


## Where the streams of the fall over samples run.x..run.y land: on its
## ledges and at its foot.
func add_landings(c: RibbonCentreline, f: RibbonFallSpans, run: Vector2i, ground: TerrainSource) -> void:
	var face := faces[f.face_of[run.x]]
	var pts := c.pts
	var tans := c.tans
	if ground:
		for l in face.landings():
			var kb := run.x
			for k in range(run.x, run.y + 1):
				if absf(f.sheet[k] - l.y) < absf(f.sheet[kb] - l.y):
					kb = k
			var p := Vector2(pts[kb].x, pts[kb].z) + Vector2(-tans[kb].y, tans[kb].x) * l.x
			var o := face.rock_out(l.x, l.y + 0.05) + 0.15
			ledges.append([Vector3(p.x + tans[kb].x * o, ground.surface_at(p.x, p.y) + 0.2, p.y + tans[kb].y * o),
					tans[kb], minf(l.z * 1.5, face.row_h)])
	var kf := mini(run.y + 1, c.count - 1)
	for ft in face.feet():
		var p := Vector2(pts[kf].x, pts[kf].z) + Vector2(-tans[kf].y, tans[kf].x) * ft.x
		feet.append([Vector3(p.x, pts[kf].y, p.y), tans[kf], face.height, ft.y])
