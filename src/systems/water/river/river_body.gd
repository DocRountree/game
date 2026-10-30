class_name RiverBody
extends WaterBody
## Every river in the world as one water body, from the generated rivers
## (WorldData.river_network): the surface follows each river's level
## (falling downstream, blended smoothly between nearby reaches), the current
## runs along it, fastest mid-channel. RiverWater draws the water; this is
## what buoyancy, swimming and sampling see, and it hands the shader the
## ocean's ripples and small waves (the clock and sun are shader globals).

var material: ShaderMaterial

var network: RiverNetwork
var _ocean: Ocean


func _init() -> void:
	kind = Kind.RIVER
	priority = 2
	salinity_ppt = 0.2
	temperature_c = 13.0
	turbidity = 0.08
	name = "RiverBody"


func setup(world: WorldData) -> void:
	network = world.river_network


func _ready() -> void:
	for b in WaterBody.all():
		if b is Ocean:
			_ocean = b


func _process(_delta: float) -> void:
	if material == null:
		return
	# the wakes and ripples round the player (the ocean's simulation, which
	# drifts with the current in a river)
	if _ocean and _ocean.ripples and _ocean.ripples.enabled:
		material.set_shader_parameter("ripple_tex", _ocean.ripples.texture)
		material.set_shader_parameter("ripple_rect", Vector3(_ocean.ripples.origin.x, _ocean.ripples.origin.y, _ocean.ripples.size()))
	# the small waves: the sea's FFT slopes (carried along the current in the shader)
	if _ocean and _ocean.small_waves and _ocean.small_waves.enabled:
		for c in OceanFFT.CASCADES:
			material.set_shader_parameter("fft_%d" % c, _ocean.small_waves.textures[c])
		material.set_shader_parameter("fft_sizes", _ocean.small_waves.sizes)
		material.set_shader_parameter("has_fft", true)


## The channel at a point (RiverNetwork.channel()): "r", "surface", "flow".
func channel(x: float, z: float) -> Dictionary:
	return network.channel(x, z) if network else {}


func contains_point(x: float, z: float) -> bool:
	var c := channel(x, z)
	return not c.is_empty() and c.r < 1.4 and Terrain.height_at(x, z) < c.surface


func surface_height(x: float, z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	var c := channel(x, z)
	return float(c.surface) if not c.is_empty() else -INF


func flow_at(x: float, z: float) -> Vector3:
	var c := channel(x, z)
	if c.is_empty() or c.r >= 1.4:
		return Vector3.ZERO
	var f: Vector2 = c.flow
	return Vector3(f.x, 0.0, f.y)
