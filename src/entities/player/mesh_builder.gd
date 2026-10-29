class_name MeshBuilder
extends RefCounted
## Collects geometry into one ArrayMesh whose vertices carry their colour slot
## (COLOR.r, see character.gdshader) and how far they sway (COLOR.g): the
## character's body, hair and accessories are each one mesh, one draw call.

var verts := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var idx := PackedInt32Array()


## A primitive mesh, transformed, in colour slot `slot`.
func add_mesh(mesh: Mesh, xf: Transform3D, slot: int, sway := 0.0) -> void:
	var a := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var ix: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var nb := xf.basis.inverse().transposed()
	var base := verts.size()
	var c := Color(slot / 255.0, sway, 0.0, 1.0)
	for i in v.size():
		verts.append(xf * v[i])
		normals.append((nb * n[i]).normalized())
		colors.append(c)
	for i in ix:
		idx.append(base + i)


## A tapered tube along `points` (radii: each point's), `sides` round; the
## sway grows from 0 at the first point to `sway` at the last.
func add_tube(points: PackedVector3Array, radii: PackedFloat32Array, sides: int, slot: int, sway := 0.0) -> void:
	var n := points.size()
	if n < 2:
		return
	var base := verts.size()
	var ref := Vector3.UP
	for k in n:
		var t := (points[mini(k + 1, n - 1)] - points[maxi(k - 1, 0)]).normalized()
		if absf(t.dot(ref)) > 0.95:
			ref = Vector3.RIGHT
		var u := t.cross(ref).normalized()
		var w := t.cross(u)
		var f := float(k) / (n - 1)
		var c := Color(slot / 255.0, sway * f * f, 0.0, 1.0)
		for s in sides:
			var ang := TAU * s / sides
			var off := u * cos(ang) + w * sin(ang)
			verts.append(points[k] + off * radii[k])
			normals.append(off)
			colors.append(c)
	for k in n - 1:
		for s in sides:
			var a := base + k * sides + s
			var b := base + k * sides + (s + 1) % sides
			idx.append_array([a, a + sides, b, b, a + sides, base + (k + 1) * sides + (s + 1) % sides])


## A surface patch from a grid of points (rows x cols, row-major); `flip`
## turns it over (the winding decides which side faces out).
func add_grid(points: PackedVector3Array, rows: int, cols: int, slot: int, sway := 0.0, flip := false) -> void:
	var base := verts.size()
	var c := Color(slot / 255.0, sway, 0.0, 1.0)
	for r in rows:
		for q in cols:
			var p := points[r * cols + q]
			verts.append(p)
			colors.append(c)
			var du := points[r * cols + mini(q + 1, cols - 1)] - points[r * cols + maxi(q - 1, 0)]
			var dv := points[mini(r + 1, rows - 1) * cols + q] - points[maxi(r - 1, 0) * cols + q]
			normals.append(dv.cross(du).normalized() * (-1.0 if flip else 1.0))
	for r in rows - 1:
		for q in cols - 1:
			var a := base + r * cols + q
			if flip:
				idx.append_array([a, a + 1, a + cols, a + 1, a + cols + 1, a + cols])
			else:
				idx.append_array([a, a + cols, a + 1, a + 1, a + cols, a + cols + 1])


func triangles() -> int:
	return idx.size() / 3


func commit() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
