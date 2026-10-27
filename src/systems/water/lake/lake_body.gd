class_name LakeBody
extends WaterBody
## A lake from the world bake: a flat surface at its current level, drawn
## with the ocean's water shader minus the swell (only small wind ripples),
## masked so it shows only inside its own basin. Terminal lakes (no outlet)
## are salty.

var level := 0.0
var rect := Rect2()
var lake_index := 0

var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _ocean: WaterBody


func setup(lake: Dictionary, index: int, ocean: WaterBody) -> void:
	kind = Kind.LAKE
	priority = 1
	level = float(lake.level)
	rect = lake.rect
	lake_index = index
	salinity_ppt = 45.0 if lake.endorheic else 0.3
	temperature_c = 12.0
	turbidity = 0.12
	name = "Lake%d" % index
	_ocean = ocean


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var ocean_mat: ShaderMaterial = null
	if _ocean and _ocean.has_node("Surface"):
		ocean_mat = (_ocean.get_node("Surface") as MeshInstance3D).material_override
	if ocean_mat == null:
		return
	_material = ocean_mat.duplicate()
	_material.set_shader_parameter("swell_scale", 0.0)
	_material.set_shader_parameter("detail_strength", 0.18)
	_material.set_shader_parameter("surface_level", level)
	_material.set_shader_parameter("flat_spacing", 0.5)
	_material.set_shader_parameter("masked", true)
	_material.set_shader_parameter("lake_mask", Terrain.current().lake_mask_texture())
	_material.set_shader_parameter("seabed", Terrain.current().seabed_texture())
	_material.set_shader_parameter("world_size", Terrain.maps().size)
	_material.set_shader_parameter("has_seabed", true)
	_material.set_shader_parameter("absorption", Vector3(0.38, 0.1, 0.09))
	var plane := PlaneMesh.new()
	var r := rect.grow(Terrain.maps().cell * 4.0)
	plane.size = r.size
	_mesh = MeshInstance3D.new()
	_mesh.mesh = plane
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	_mesh.global_position = Vector3(r.get_center().x, level, r.get_center().y)


func _process(_delta: float) -> void:
	if _material == null or _ocean == null:
		return
	var src: ShaderMaterial = (_ocean.get_node("Surface") as MeshInstance3D).material_override
	for p: StringName in [&"time", &"ripple_rect", &"sun_direction", &"sun_color", &"ripple_tex",
			&"fft_0", &"fft_1", &"fft_2"]:
		_material.set_shader_parameter(p, src.get_shader_parameter(p))


func contains_point(x: float, z: float) -> bool:
	if not rect.grow(200.0).has_point(Vector2(x, z)):
		return false
	var maps := Terrain.maps()
	return maps != null and absf(maps.lake_level_at(x, z) - level) < 0.5 and Terrain.height_at(x, z) < level


func surface_height(_x: float, _z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	return level


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, level - Terrain.height_at(x, z))
