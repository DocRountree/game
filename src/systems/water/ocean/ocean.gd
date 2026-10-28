@tool
class_name Ocean
extends WaterBody
## Open ocean: analytic Gerstner swell plus an interactive ripple simulation.
## Endless, so it is the fallback wherever no lake or river claims a point.
##
## Physics asks surface_height() (via Water) and the water shader evaluates the
## same waves, so floating things ride exactly the surface that is drawn.

@export var waves: Array[OceanWave] = []:
	set(value):
		waves = value
		_rebuild_waves()
@export_range(0.0, 1.0) var steepness := 0.8  ## Gerstner Q. Keep sum(Q*k*A) < 1 or crests loop.
@export var focus: Node3D        ## The ripple grid stays centred on this (usually the player).
@export var sun: DirectionalLight3D

var time := 0.0

var _n := 0
var _dx := PackedFloat32Array()
var _dz := PackedFloat32Array()
var _k := PackedFloat32Array()
var _amp := PackedFloat32Array()
var _omega := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _wavelength := PackedFloat32Array()
var _sources := PackedFloat32Array()
var _shore_set := false

@onready var surface: OceanSurface = $Surface
@onready var ripples: RippleSim = $Ripples
@onready var small_waves: OceanFFT = $SmallWaves
@onready var _material: ShaderMaterial = surface.material_override


func _ready() -> void:
	_rebuild_waves()


func _rebuild_waves() -> void:
	_n = waves.size()
	for arr: PackedFloat32Array in [_dx, _dz, _k, _amp, _omega, _phase, _wavelength]:
		arr.resize(_n)
	var wave_vecs: Array[Vector4] = []
	var wave_vecs2: Array[Vector2] = []
	for i in _n:
		var w := waves[i]
		var a := deg_to_rad(w.direction_degrees)
		_dx[i] = cos(a)
		_dz[i] = sin(a)
		_k[i] = TAU / w.wavelength
		_amp[i] = w.amplitude
		_omega[i] = sqrt(Water.G * _k[i])   # deep-water dispersion
		_phase[i] = w.phase
		_wavelength[i] = w.wavelength
		wave_vecs.append(Vector4(_dx[i], _dz[i], _k[i], _amp[i]))
		wave_vecs2.append(Vector2(_omega[i], _phase[i]))
	if _material:
		_material.set_shader_parameter("waves", wave_vecs)
		_material.set_shader_parameter("waves2", wave_vecs2)
		_material.set_shader_parameter("steepness", steepness)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	time += delta
	if focus:
		ripples.recenter(focus.global_position)
	_gather_ripple_sources()
	ripples.step(delta, _sources)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		time += delta   # animate the preview; in game, physics owns the clock
	_material.set_shader_parameter("time", time)
	# the ripple and small-wave simulations only run in game (not @tool)
	if not Engine.is_editor_hint():
		_material.set_shader_parameter("ripple_tex", ripples.texture)
		small_waves.update(time)
		for c in OceanFFT.CASCADES:
			_material.set_shader_parameter("fft_%d" % c, small_waves.textures[c])
		_material.set_shader_parameter("fft_sizes", small_waves.sizes)
	if not Engine.is_editor_hint():
		_material.set_shader_parameter("ripple_rect", Vector3(ripples.origin.x, ripples.origin.y, ripples.size()))
	if not _shore_set and not Engine.is_editor_hint() and Terrain.current() and Terrain.current().world:
		_shore_set = true
		var t := Terrain.current()
		var tex := t.height_textures()
		_material.set_shader_parameter("height_hi", tex[0])
		_material.set_shader_parameter("height_lo", tex[1])
		_material.set_shader_parameter("world_size", t.world.size)
		_material.set_shader_parameter("texels", t.world.texels)
		_material.set_shader_parameter("h_min", t.world.h_min)
		_material.set_shader_parameter("h_scale", t.world.h_scale)
		_material.set_shader_parameter("has_seabed", true)
	if sun:
		_material.set_shader_parameter("sun_direction", sun.global_basis.z)
		_material.set_shader_parameter("sun_color", Vector3(sun.light_color.r, sun.light_color.g, sun.light_color.b) * sun.light_energy)
	var cam := get_viewport().get_camera_3d()
	if cam and not Engine.is_editor_hint():
		surface.global_position = Vector3(cam.global_position.x, 0.0, cam.global_position.z)


## Swell height (m) above world point (x, z).
## footprint > 0 low-passes the waves: a hull ignores wavelengths shorter than itself.
## ripple_radius >= 0 adds the interactive ripples, averaged on a ring of that
## radius (0 = at the point) so an object doesn't feel its own displacement trough.
func surface_height(x: float, z: float, footprint := 0.0, ripple_radius := -1.0) -> float:
	var amp := _amp
	var depth := -Terrain.height_at(x, z) if Terrain.current() else INF
	if footprint > 0.0 or depth < 60.0:
		amp = _amp.duplicate()
		for i in _n:
			if footprint > 0.0:
				amp[i] *= exp(-2.0 * pow(footprint / _wavelength[i], 2.0))
			amp[i] *= smoothstep(0.0, 0.35 * _wavelength[i], depth)   # waves shoal out (as the shader)
	# Gerstner moves water sideways: find the undisplaced point that lands on (x, z)
	var x0 := x
	var z0 := z
	for _iter in 3:
		var sx := 0.0
		var sz := 0.0
		for i in _n:
			var c := cos(_k[i] * (_dx[i] * x0 + _dz[i] * z0) - _omega[i] * time + _phase[i])
			sx += steepness * amp[i] * _dx[i] * c
			sz += steepness * amp[i] * _dz[i] * c
		x0 = x - sx
		z0 = z - sz
	var h := 0.0
	for i in _n:
		h += amp[i] * sin(_k[i] * (_dx[i] * x0 + _dz[i] * z0) - _omega[i] * time + _phase[i])
	if ripple_radius >= 0.0:
		h += ripples.sample_ring(x, z, ripple_radius)
	return h


## The sea is wherever the ground is below sea level (a little above, for
## the waves washing up the beach).
func contains_point(x: float, z: float) -> bool:
	return Terrain.height_at(x, z) < 0.3


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, -Terrain.height_at(x, z)) if Terrain.current() else floor_depth


func ripple_height(x: float, z: float, r := 0.0) -> float:
	return ripples.sample_ring(x, z, r)


func ripple_slope(x: float, z: float) -> Vector2:
	return ripples.slope(x, z)


func _gather_ripple_sources() -> void:
	_sources.clear()
	for node in get_tree().get_nodes_in_group(&"ripple_sources"):
		var s: PackedFloat32Array = node.ripple_source()
		if s.size() == 8 and _sources.size() < RippleSim.MAX_SOURCES * 8:
			_sources.append_array(s)
