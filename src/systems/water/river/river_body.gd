class_name RiverBody
extends WaterBody
## Every flowing river in the world, as one water body. The surface follows
## each river's centreline (falling downstream), the current runs along it,
## fastest mid-channel. Drawn as ribbons along the wet stretches with
## river.gdshader (flow-mapped ripples and foam after P_Malin's "Where the
## River Goes"); dry riverbeds have no water at all.

const BANK_OVERLAP := 1.25   ## Ribbons reach this far past the banks (under the ground).

var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _sun: DirectionalLight3D
var _time := 0.0


func _init() -> void:
	kind = Kind.RIVER
	priority = 2
	salinity_ppt = 0.2
	temperature_c = 11.0
	turbidity = 0.08
	name = "Rivers"


func _ready() -> void:
	if Engine.is_editor_hint() or Terrain.maps() == null:
		return
	_material = ShaderMaterial.new()
	_material.shader = preload("res://src/systems/water/river/river.gdshader")
	_mesh = MeshInstance3D.new()
	_mesh.mesh = build_mesh(Terrain.maps())
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)


func set_sun(sun: DirectionalLight3D) -> void:
	_sun = sun


func _process(delta: float) -> void:
	if _material == null:
		return
	_time += delta
	_material.set_shader_parameter("time", _time)
	if _sun:
		_material.set_shader_parameter("sun_direction", _sun.global_basis.z)
		_material.set_shader_parameter("sun_color", Vector3(_sun.light_color.r, _sun.light_color.g, _sun.light_color.b) * _sun.light_energy)


## Ribbons along the wet stretches: UV.x across (+-1 at the banks), UV.y along
## (m); CUSTOM0 = flow direction x, z, speed (m/s), centre depth (m).
static func build_mesh(maps: WorldMaps) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	for river in maps.rivers:
		var pts: PackedVector3Array = river.points
		var hw: PackedFloat32Array = river.half_width
		var dep: PackedFloat32Array = river.depth
		var spd: PackedFloat32Array = river.speed
		var wet: PackedByteArray = river.wet
		var along := 0.0
		var run_start := -1
		for k in pts.size():
			if k > 0:
				along += Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length()
			var on := wet[k] == 1 or (k > 0 and wet[k - 1] == 1)
			if not on:
				run_start = -1
				continue
			var a := pts[maxi(k - 1, 0)]
			var b := pts[mini(k + 1, pts.size() - 1)]
			var t := Vector2(b.x - a.x, b.z - a.z).normalized()
			var nrm := Vector2(-t.y, t.x)
			var w := hw[k] * BANK_OVERLAP
			var base := verts.size()
			verts.append(Vector3(pts[k].x + nrm.x * w, pts[k].y, pts[k].z + nrm.y * w))
			verts.append(Vector3(pts[k].x - nrm.x * w, pts[k].y, pts[k].z - nrm.y * w))
			uvs.append(Vector2(BANK_OVERLAP, along))
			uvs.append(Vector2(-BANK_OVERLAP, along))
			for _j in 2:
				custom.append_array([t.x, t.y, spd[k] if wet[k] == 1 else spd[k] * 0.5, dep[k]])
			if run_start >= 0:
				idx.append_array([base - 2, base - 1, base, base - 1, base + 1, base])
			run_start = base
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	var fmt := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	return mesh


func contains_point(x: float, z: float) -> bool:
	var maps := Terrain.maps()
	if maps == null:
		return false
	var r := maps.river_at(x, z)
	return not r.is_empty() and r.wet and r.distance < r.half_width and Terrain.height_at(x, z) < r.surface


func surface_height(x: float, z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	var r := Terrain.maps().river_at(x, z) if Terrain.maps() else {}
	return float(r.surface) if not r.is_empty() else global_position.y


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, surface_height(x, z) - Terrain.height_at(x, z))


## The current: along the river, fastest mid-channel, slow at the banks.
func flow_at(x: float, z: float) -> Vector3:
	var r := Terrain.maps().river_at(x, z) if Terrain.maps() else {}
	if r.is_empty() or not r.wet:
		return Vector3.ZERO
	var across: float = clampf(float(r.distance) / float(r.half_width), 0.0, 1.0)
	var d: Vector2 = r.flow_dir
	return Vector3(d.x, 0.0, d.y) * float(r.speed) * (1.0 - 0.7 * across * across)
