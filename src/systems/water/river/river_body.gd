class_name RiverBody
extends WaterBody
## Every river and oxbow lake in the world, as one water body, from the
## baked channels (RiverNetwork): the surface follows each river's centreline
## (falling downstream, blended smoothly between nearby reaches, exactly as
## the terrain compute shader does), the current runs along it, fastest
## mid-channel. Terrain draws the water (river.gdshader on RiverRibbons, ribbon
## meshes that follow each channel); this keeps the shader's clock and sun in
## step with the ocean's.

var material: ShaderMaterial   ## Set by Terrain.
var ocean: WaterBody           ## Set by Terrain.

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


func _channel(x: float, z: float) -> Dictionary:
	var maps := Terrain.maps()
	return maps.river_at(x, z) if maps else {}


func contains_point(x: float, z: float) -> bool:
	var r := _channel(x, z)
	if r.is_empty() or r.r >= 1.6:
		return false   # (the water reaches a little past the bank where the ground dips)
	var ground := Terrain.height_at(x, z)
	if ground < Terrain.maps().lake_level_at(x, z):
		return false   # where a river runs into a lake, the lake has it
	return ground < r.surface


func surface_height(x: float, z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	var r := _channel(x, z)
	return float(r.surface) if not r.is_empty() else global_position.y


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, surface_height(x, z) - Terrain.height_at(x, z))


## The current: along the river (turning smoothly round bends), fastest
## mid-channel, slower at the banks.
func flow_at(x: float, z: float) -> Vector3:
	var r := _channel(x, z)
	if r.is_empty() or r.r >= 1.6:
		return Vector3.ZERO
	var d: Vector2 = r.flow_dir
	return Vector3(d.x, 0.0, d.y) * float(r.speed)
