@tool
class_name OceanSurface
extends MeshInstance3D
## Camera-centred polar grid: ~8 cm between vertices underfoot, ~40 m at the
## horizon. Each vertex carries its local spacing (UV.x) so the shader can drop
## waves too short for that ring to resolve.

@export var rings := 200
@export var segments := 256
@export var inner_spacing := 0.08  ## Vertex spacing at the centre (m).
@export var growth := 0.032        ## Spacing grows by exp(growth) per ring.


func _ready() -> void:
	if not Engine.is_editor_hint():
		rings = QualitySettings.current().ocean_rings
		segments = QualitySettings.current().ocean_segments
	mesh = build_mesh()
	# displacement moves vertices; never cull the ocean
	custom_aabb = AABB(Vector3(-3000, -50, -3000), Vector3(6000, 100, 6000))


func build_mesh() -> ArrayMesh:
	var count := (rings + 1) * segments
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	for i in rings + 1:
		var r := inner_spacing * (exp(growth * i) - 1.0) / growth
		var spacing := maxf(inner_spacing * exp(growth * i), r * TAU / segments)
		for j in segments:
			var a := TAU * j / segments
			var v := i * segments + j
			verts[v] = Vector3(r * cos(a), 0.0, r * sin(a))
			normals[v] = Vector3.UP
			uvs[v] = Vector2(spacing, 0.0)
	var indices := PackedInt32Array()
	indices.resize(rings * segments * 6)
	var n := 0
	for i in rings:
		for j in segments:
			var a := i * segments + j
			var b := i * segments + (j + 1) % segments
			var c := (i + 1) * segments + j
			var d := (i + 1) * segments + (j + 1) % segments
			indices[n] = a
			indices[n + 1] = b
			indices[n + 2] = c
			indices[n + 3] = b
			indices[n + 4] = d
			indices[n + 5] = c
			n += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
