class_name Lightning
extends Node3D
## Thunderstorm light: flashes inside the cloud deck (about every flash_interval
## seconds) that light up a patch of cloud and the sea, and distant
## cloud-to-ground strokes (about every bolt_interval seconds): jagged, branching
## channels near the horizon that flicker for a fraction of a second. Random
## (Poisson) timing; only while Weather says a storm is on.

const BOLT_DEPTH := 2200.0          ## Same depth squeeze as the clouds (see clouds.gdshader).

@export var weather: Weather
@export var clouds: Clouds
@export var flash_interval := 5.0
@export var bolt_interval := 45.0
@export var flash_light_energy := 0.6

var flashes := 0                    ## Counts, for tests and logs.
var bolts := 0

var _rng := RandomNumberGenerator.new()
var _flash_wait := 0.0
var _bolt_wait := 0.0
var _flash_t := 10.0                # seconds since the current flash began
var _flash_pos := Vector3.ZERO
var _flash_strength := 0.0
var _bolt_t := 10.0
var _light: DirectionalLight3D
var _bolt: MeshInstance3D
var _mesh := ImmediateMesh.new()


func _ready() -> void:
	_rng.randomize()
	_light = DirectionalLight3D.new()
	_light.light_color = Color(0.8, 0.85, 1.0)
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	_light.visible = false
	add_child(_light)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_fog = true
	_bolt = MeshInstance3D.new()
	_bolt.mesh = _mesh
	_bolt.material_override = mat
	_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bolt.top_level = true
	_bolt.extra_cull_margin = 16384.0
	add_child(_bolt)
	_flash_wait = _next(flash_interval)
	_bolt_wait = _next(bolt_interval)


func _process(delta: float) -> void:
	var storm := weather != null and weather.storm_active()
	if storm:
		_flash_wait -= delta
		_bolt_wait -= delta
		if _flash_wait <= 0.0:
			flash()
			_flash_wait = _next(flash_interval)
		if _bolt_wait <= 0.0:
			strike()
			_bolt_wait = _next(bolt_interval)
	_flash_t += delta
	_bolt_t += delta
	# a flash flickers: a few quick pulses over ~0.4 s
	var f := 0.0
	if _flash_t < 0.5:
		f = _flash_strength * exp(-_flash_t * 6.0) * (0.6 + 0.4 * sin(_flash_t * 70.0))
	if clouds:
		clouds.set_flash(_flash_pos, maxf(f, 0.0))
	_light.light_energy = flash_light_energy * maxf(f, 0.0)
	_light.visible = _light.light_energy > 0.001
	# a bolt shows for ~0.3 s, with a re-strike flicker
	_bolt.visible = _bolt_t < 0.32 and (_bolt_t < 0.07 or _bolt_t > 0.12)


## An in-cloud flash somewhere over the deck.
func flash(at := Vector3.INF, strength := -1.0) -> void:
	if at == Vector3.INF:
		flashes += 1   # counts in-cloud flashes only, not the glow of a ground stroke
	var cam := get_viewport().get_camera_3d()
	var c := cam.global_position if cam else Vector3.ZERO
	if at == Vector3.INF:
		at = clouds.random_storm_point(_rng, c) if clouds else Vector3.INF
		if at == Vector3.INF:   # no thunderhead in reach: nothing to light
			return
	_flash_pos = at
	_flash_strength = strength if strength >= 0.0 else _rng.randf_range(0.5, 1.4)
	_flash_t = 0.0
	_light.global_basis = Basis.looking_at((c - at).normalized() * Vector3(1, 0, 1) + Vector3.DOWN, Vector3.FORWARD)


## A distant cloud-to-ground stroke, with a bright flash where it leaves the cloud.
func strike(azimuth := NAN) -> void:
	bolts += 1
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := cam.global_position
	# from the base of a thunderhead to the ground beneath it
	var src: Vector3 = clouds.random_storm_point(_rng, c, 60000.0) if clouds else Vector3.INF
	if src == Vector3.INF:
		return
	var top := Vector3(src.x, clouds.altitude, src.z)
	var foot := top + Vector3(_rng.randf_range(-1200.0, 1200.0), -clouds.altitude, _rng.randf_range(-1200.0, 1200.0))
	foot.y = 0.0
	_build_bolt(c, top, foot)
	_bolt_t = 0.0
	flash(top, 1.6)


func _build_bolt(cam: Vector3, top: Vector3, foot: Vector3) -> void:
	var main := _channel(top, foot, 7, 0.22)
	var strands: Array = [[main, 1.0]]
	for i in _rng.randi_range(2, 4):   # branches off the upper part
		var j := _rng.randi_range(2, main.size() / 2)
		var start: Vector3 = main[j]
		var end := start + Vector3(_rng.randf_range(-700, 700), -_rng.randf_range(300, 900), _rng.randf_range(-700, 700))
		strands.append([_channel(start, end, 5, 0.3), 0.45])
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for s: Array in strands:
		var pts: Array[Vector3] = s[0]
		for w: Array in [[14.0, 0.25], [5.0, 1.0]]:   # soft glow, then the bright core
			_ribbon(cam, pts, w[0] * s[1], Color(0.85, 0.9, 1.0) * (w[1] * s[1] * 3.0))
	_mesh.surface_end()
	_bolt.global_transform = Transform3D(Basis(), cam)


# A jagged channel by midpoint displacement.
func _channel(a: Vector3, b: Vector3, levels: int, rough: float) -> Array[Vector3]:
	var pts: Array[Vector3] = [a, b]
	for l in levels:
		var out: Array[Vector3] = []
		for i in pts.size() - 1:
			var p: Vector3 = pts[i]
			var q: Vector3 = pts[i + 1]
			var len := p.distance_to(q)
			out.append(p)
			out.append((p + q) * 0.5 + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.3, 0.3), _rng.randf_range(-1, 1)) * len * rough)
		out.append(pts[-1])
		pts = out
	return pts


# A camera-facing ribbon through world points, squeezed into the view depth range
# like the clouds (so it sits in front of the sky and behind nearer things).
func _ribbon(cam: Vector3, pts: Array[Vector3], width: float, colour: Color) -> void:
	var local: Array[Vector3] = []
	var widths: Array[float] = []
	for p in pts:
		var v := p - cam
		var d := v.length()
		var k := BOLT_DEPTH / (d + BOLT_DEPTH)
		local.append(v * k)
		widths.append(width * k)
	for i in local.size() - 1:
		var a := local[i]
		var b := local[i + 1]
		var side := (b - a).cross(a).normalized()
		_mesh.surface_set_color(colour)
		var a1 := a + side * widths[i]
		var a2 := a - side * widths[i]
		var b1 := b + side * widths[i + 1]
		var b2 := b - side * widths[i + 1]
		for v in [a1, a2, b1, b1, a2, b2]:
			_mesh.surface_add_vertex(v)


func _next(mean: float) -> float:
	return -log(maxf(_rng.randf(), 1e-4)) * mean
