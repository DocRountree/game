class_name TreeSpawner
extends ChunkSpawner
## Stand-in trees until real ones exist: dark green pyramids, scattered by
## the generator's forest mask (WorldData.trees), 7-25 m tall, each chunk one
## multimesh fading out with distance (the forests stay visible beyond as the
## ground's darker forest floor). They give the eye a known size everywhere.

var world: WorldData
var _mesh: ArrayMesh
var _buckets := {}   # Vector2i chunk -> PackedInt32Array of tree indices


func _init(w: WorldData) -> void:
	world = w
	view = 3200.0
	_mesh = _pyramid()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.surface_set_material(0, mat)
	var half := w.size * 0.5
	for i in w.tree_count():
		var t := w.tree(i)
		var key := Vector2i(floori((t.x + half) / ChunkStreamer.CHUNK), floori((t.z + half) / ChunkStreamer.CHUNK))
		if not _buckets.has(key):
			_buckets[key] = PackedInt32Array()
		var ids: PackedInt32Array = _buckets[key]
		ids.append(i)
		_buckets[key] = ids


func build(cx: int, cz: int, _rect: Rect2, centre: Vector3) -> Node3D:
	var ids: PackedInt32Array = _buckets.get(Vector2i(cx, cz), PackedInt32Array())
	if ids.is_empty():
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = 11 + cx * 7919 + cz * 104729
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _mesh
	mm.instance_count = ids.size()
	for k in ids.size():
		var t := world.tree(ids[k])
		var h := world.tree_height(ids[k])
		var w := h * rng.randf_range(0.8, 1.15)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w))
		mm.set_instance_transform(k, Transform3D(basis, Vector3(t.x, t.y - 0.3, t.z) - centre))
		var g := rng.randf()
		mm.set_instance_color(k, Color(0.07 + 0.05 * g, 0.16 + 0.08 * g, 0.06 + 0.03 * g))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.visibility_range_end = view
	mi.visibility_range_end_margin = 400.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mi


# A unit pyramid (1 m tall, 0.66 m across), flat shaded: four triangles.
static func _pyramid() -> ArrayMesh:
	var apex := Vector3(0.0, 1.0, 0.0)
	var r := 0.33
	var base := [Vector3(-r, 0.0, -r), Vector3(r, 0.0, -r), Vector3(r, 0.0, r), Vector3(-r, 0.0, r)]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for i in 4:
		var a: Vector3 = base[i]
		var b: Vector3 = base[(i + 1) % 4]
		var n := (apex - a).cross(b - a).normalized()   # outward and up
		verts.append_array([a, apex, b])
		normals.append_array([n, n, n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
