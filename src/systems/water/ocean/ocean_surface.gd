@tool
class_name OceanSurface
extends MeshInstance3D
## Camera-centred polar grid: ~8 cm between vertices underfoot, ~40 m at
## 1.5 km, then a few coarse rings out to the horizon seen from a mountain.
## Each vertex carries its local spacing (UV.x) so the shader can drop
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
	custom_aabb = AABB(Vector3(-FAR_RADIUS, -400, -FAR_RADIUS), Vector3(FAR_RADIUS * 2.0, 450, FAR_RADIUS * 2.0))


const FAR_RADIUS := 60000.0   ## The coarse rings reach this far (m).
const FAR_RINGS := 16


func build_mesh() -> ArrayMesh:
	var radii := PackedFloat32Array()
	var spacings := PackedFloat32Array()
	for i in rings + 1:
		var r := inner_spacing * (exp(growth * i) - 1.0) / growth
		radii.append(r)
		spacings.append(maxf(inner_spacing * exp(growth * i), r * TAU / segments))
	var r_last := radii[rings]
	for j in range(1, FAR_RINGS + 1):
		var r := r_last * pow(FAR_RADIUS / r_last, float(j) / FAR_RINGS)
		radii.append(r)
		spacings.append(r * TAU / segments)
	var total := radii.size() - 1
	var count := (total + 1) * segments
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	for i in total + 1:
		var r := radii[i]
		var spacing := spacings[i]
		for j in segments:
			var a := TAU * j / segments
			var v := i * segments + j
			verts[v] = Vector3(r * cos(a), 0.0, r * sin(a))
			normals[v] = Vector3.UP
			uvs[v] = Vector2(spacing, 0.0)
	var indices := PackedInt32Array()
	indices.resize(total * segments * 6)
	var n := 0
	for i in total:
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
