class_name RiverBody
extends WaterBody
## Every river and oxbow lake in the world, as one water body, from the
## baked channels (RiverNetwork): the surface follows each river's centreline
## (falling downstream), the current runs along it, fastest mid-channel; oxbow
## lakes are still. Terrain draws the water (river.gdshader on its own
## patches); this keeps the shader's clock, sun and small-wave textures in
## step with the ocean's. Dry riverbeds and meander scars hold no water.

var material: ShaderMaterial   ## Set by Terrain.
var ocean: WaterBody           ## Set by Terrain: the source of the small waves.

var _sun: DirectionalLight3D
var _time := 0.0


func _init() -> void:
	kind = Kind.RIVER
	priority = 2
	salinity_ppt = 0.2
	temperature_c = 11.0
	turbidity = 0.08
	name = "Rivers"


func set_sun(sun: DirectionalLight3D) -> void:
	_sun = sun


func _process(delta: float) -> void:
	if material == null:
		return
	_time += delta
	material.set_shader_parameter("time", _time)
	if _sun:
		material.set_shader_parameter("sun_direction", _sun.global_basis.z)
		material.set_shader_parameter("sun_color", Vector3(_sun.light_color.r, _sun.light_color.g, _sun.light_color.b) * _sun.light_energy)
	if ocean and ocean.has_node("Surface"):
		var src: ShaderMaterial = (ocean.get_node("Surface") as MeshInstance3D).material_override
		# the ocean's own colours too, so where the sea runs up a river mouth
		# the hand-off doesn't show
		for p: StringName in [&"fft_0", &"fft_1", &"fft_2", &"fft_sizes", &"foam_noise",
				&"deep_color", &"scatter_color", &"absorption"]:
			material.set_shader_parameter(p, src.get_shader_parameter(p))


func _channel(x: float, z: float) -> Dictionary:
	var maps := Terrain.maps()
	return maps.river_at(x, z) if maps else {}


func contains_point(x: float, z: float) -> bool:
	var r := _channel(x, z)
	if r.is_empty() or not r.wet or r.r >= 1.0:
		return false
	var ground := Terrain.height_at(x, z)
	if ground < Terrain.maps().lake_level_at(x, z):
		return false   # where a river runs into a lake, the lake has it
	return ground < r.surface


func surface_height(x: float, z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	var r := _channel(x, z)
	return float(r.surface) if not r.is_empty() else global_position.y


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, surface_height(x, z) - Terrain.height_at(x, z))


## The current: along the river, fastest mid-channel, slow at the banks.
func flow_at(x: float, z: float) -> Vector3:
	var r := _channel(x, z)
	if r.is_empty() or not r.wet:
		return Vector3.ZERO
	var across: float = clampf(float(r.r), 0.0, 1.0)
	var d: Vector2 = r.flow_dir
	return Vector3(d.x, 0.0, d.y) * float(r.speed) * (1.0 - 0.6 * across * across)
