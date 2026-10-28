class_name TreeScatter
extends Node3D
## Stand-in trees until real ones exist: dark green pyramids, scattered by
## the generator's forest mask (WorldData.trees), 7-25 m tall. They give the
## eye a known size everywhere. Drawn in square chunks, each one multimesh
## that fades out with distance (the forests stay visible beyond as the
## ground's darker forest floor).

const CHUNK := 512.0
const VIEW := 3200.0        ## Chunks fade out by here (m).

var count := 0


func setup(world: WorldData) -> void:
	var mesh := _pyramid()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var per_side := ceili(world.size / CHUNK)
	var buckets: Array[PackedInt32Array] = []
	buckets.resize(per_side * per_side)
	for b in buckets.size():
		buckets[b] = PackedInt32Array()
	count = world.tree_count()
	for i in count:
		var t := world.tree(i)
		var cx := clampi(int((t.x + world.size * 0.5) / CHUNK), 0, per_side - 1)
		var cz := clampi(int((t.z + world.size * 0.5) / CHUNK), 0, per_side - 1)
		buckets[cz * per_side + cx].append(i)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for b in buckets.size():
		var ids := buckets[b]
		if ids.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = ids.size()
		var centre := Vector3((b % per_side + 0.5) * CHUNK - world.size * 0.5, 0.0, (b / per_side + 0.5) * CHUNK - world.size * 0.5)
		for k in ids.size():
			var t := world.tree(ids[k])
			var h := t.y
			var ground := world.height_at(t.x, t.z)
			var w := h * rng.randf_range(0.8, 1.15)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w))
			mm.set_instance_transform(k, Transform3D(basis, Vector3(t.x, ground - 0.3, t.z) - centre))
			var g := rng.randf()
			mm.set_instance_color(k, Color(0.07 + 0.05 * g, 0.16 + 0.08 * g, 0.06 + 0.03 * g))
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.position = centre
		mi.visibility_range_end = VIEW
		mi.visibility_range_end_margin = 400.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(mi)


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
