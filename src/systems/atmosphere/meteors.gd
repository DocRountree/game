@tool
class_name Meteors
extends MultiMeshInstance3D
## Shooting stars: white streaks with rounded, brightest heads that race across
## the night sky and fade. They arrive at random (a Poisson process) and only
## show at night. Drawn just in front of the stars and planets, behind clouds.
## Per instance: CUSTOM = (brightness, length/width, 0, 0).

const RADIUS := 2350.0          ## In front of the planets (2450 m), behind clouds (<= 2200 m).
const SLOTS := 16               ## Most meteors in the sky at once.

@export var mean_interval := 25.0        ## Real seconds between meteors, on average, at night.
@export_range(0.0, 1.0) var shower_chance := 0.02   ## Nights with a meteor shower (like the aurora).
@export var shower_factor := 10.0        ## How many times more meteors during a shower.
@export var width_degrees := 0.3         ## Thickness at the head; the tail tapers.

var forced_shower := false      ## Debug (F8): a shower every night.
var shower := false             ## Tonight is a meteor shower.
var launched := 0               ## Meteors so far (a tracker for logs and achievements).

var _rng := RandomNumberGenerator.new()
var _night := 0.0
var _wait := 0.0
var _active: Array[Dictionary] = []


func _ready() -> void:
	_rng.randomize()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = SLOTS
	mm.visible_instance_count = 0
	mm.custom_aabb = AABB(Vector3.ONE * -RADIUS, Vector3.ONE * RADIUS * 2.0)
	multimesh = mm
	custom_aabb = mm.custom_aabb
	_wait = _rng.randf() * mean_interval


var _night_id := -2147483648


## Whether night `night_id` (the day it began) has a meteor shower, from the world seed.
func shower_for(night_id: int) -> bool:
	if forced_shower:
		return true
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("meteor-shower:%d" % night_id)
	return rng.randf() < shower_chance


## Debug: a shower every night (on) or by chance (off); applies now.
func set_forced_shower(on: bool) -> void:
	forced_shower = on
	_night_id = -2147483648


## How dark it is (0 by day, 1 at night) and which night it is; set by Atmosphere.
func update_sky(night: float, night_id := 0) -> void:
	_night = night
	if night_id != _night_id:
		_night_id = night_id
		shower = shower_for(night_id)


## Launch a meteor now (also used by tests and for debugging).
func spawn() -> void:
	if _active.size() >= SLOTS:
		return
	var az := _rng.randf() * TAU
	var alt := deg_to_rad(_rng.randf_range(20.0, 75.0))
	var start := Vector3(cos(alt) * sin(az), sin(alt), -cos(alt) * cos(az))
	# travel along a great circle, mostly downward
	var east := Vector3.UP.cross(start).normalized()
	var down := start.cross(east).normalized() * -1.0
	var heading := _rng.randf_range(-1.2, 1.2)
	var axis := start.cross(down * cos(heading) + east * sin(heading)).normalized()
	launched += 1
	_active.append({
		"start": start, "axis": axis,
		"sweep": deg_to_rad(_rng.randf_range(15.0, 45.0)),       # how far the head travels
		"tail": deg_to_rad(_rng.randf_range(5.0, 14.0)),         # streak length
		"life": _rng.randf_range(0.4, 1.0), "age": 0.0,
		"bright": _rng.randf_range(0.6, 2.5),
	})


func active_count() -> int:
	return _active.size()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or multimesh == null:
		return
	if _night > 0.3:
		_wait -= delta
		if _wait <= 0.0:
			spawn()
			_wait = -log(maxf(_rng.randf(), 1e-4)) * mean_interval / (shower_factor if shower else 1.0)   # exponential gaps
	var cam := get_viewport().get_camera_3d()
	if cam:
		global_position = cam.global_position
	var i := 0
	var width := deg_to_rad(width_degrees) * RADIUS
	for m: Dictionary in _active.duplicate():
		m.age += delta
		var f: float = m.age / m.life
		if f >= 1.0:
			_active.erase(m)
			continue
		var head: Vector3 = (m.start as Vector3).rotated(m.axis, m.sweep * f)
		var tail_len: float = m.tail * smoothstep(0.0, 0.25, f)        # the trail grows in
		var tail: Vector3 = (m.start as Vector3).rotated(m.axis, m.sweep * f - tail_len)
		var along := (head - tail) * RADIUS
		var mid := (head + tail).normalized()
		var across := along.cross(mid).normalized() * width
		multimesh.set_instance_transform(i, Transform3D(Basis(along, across, mid), mid * RADIUS))
		var fade := smoothstep(0.0, 0.1, f) * (1.0 - smoothstep(0.7, 1.0, f))
		multimesh.set_instance_custom_data(i, Color(m.bright * fade * _night, along.length() / width, 0.0, 0.0))
		i += 1
	multimesh.visible_instance_count = i
