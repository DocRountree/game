class_name Player
extends CharacterBody3D
## Swimmer with one buoyancy probe at the chest. Slightly denser than water, so
## doing nothing means sinking; treading and swimming are force-limited kicks
## toward the surface. Can board and drive a Boat.

signal drowned

const MASS := 75.0
const HEIGHT := 1.7
const CHEST := 1.3                          ## Feet are this far below the origin (chest).
const VOLUME := 0.97 * MASS / Ocean.RHO     ## 3% denser than seawater.

@export var swim_force := 260.0             ## N
@export var breath_seconds := 20.0
@export var board_range := 5.0

var state := &"TREADING"
var breath := 1.0
var water_height := 0.0   ## Surface height here, including ripples.
var boat: Boat            ## Set while driving.

var _swell := 0.0
var _prev_h := NAN
var _lean := 0.0
var _facing := 0.0

@onready var model: Node3D = $Model
@onready var _collision: CollisionShape3D = $Collision


func _ready() -> void:
	add_to_group(&"ripple_sources")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact"):
		if boat:
			_leave_boat()
		else:
			_try_board()


func _physics_process(delta: float) -> void:
	if boat:
		_drive()
		return
	var ocean := Ocean.instance
	if ocean == null:
		return
	var pos := global_position
	_swell = ocean.height_at(pos.x, pos.z, 0.5)
	water_height = _swell + ocean.ripples.sample_ring(pos.x, pos.z, 0.8)
	var water_vy := 0.0 if is_nan(_prev_h) else (water_height - _prev_h) / delta
	_prev_h = water_height
	var s := submerged(water_height)
	var vrel := velocity.y - water_vy

	var cam := get_viewport().get_camera_3d()
	var input := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	var move := Vector3.ZERO
	if cam and input != Vector2.ZERO:
		var fwd := -cam.global_basis.z
		fwd.y = 0.0
		var right := cam.global_basis.x
		right.y = 0.0
		move = (fwd.normalized() * input.y + right.normalized() * input.x).normalized()
	var treading := Input.is_action_pressed(&"tread")
	var moving := move != Vector3.ZERO

	var fy := -MASS * Ocean.G + Ocean.RHO * Ocean.G * VOLUME * s
	if s > 0.0:
		fy -= 40.0 * vrel + 60.0 * vrel * absf(vrel)
		if treading or moving:
			# kicking is a one-sided, force-limited spring toward the surface
			var target := water_height + (0.15 if treading else -0.1)
			var lift_max := (0.30 if treading else 0.22) * MASS * Ocean.G
			fy += clampf(1500.0 * (target - pos.y) - 400.0 * vrel, 0.0, lift_max)

	var fh := Vector3.ZERO
	if s > 0.2:
		if moving:
			fh = move * swim_force
			_facing = atan2(-move.x, -move.z)
		var vh := Vector3(velocity.x, 0.0, velocity.z)
		fh -= (30.0 + 70.0 * vh.length()) * vh
		if pos.y + 0.4 > water_height - 0.5:   # near the surface: wakes shove you
			var slope := ocean.ripples.slope(pos.x, pos.z)
			fh -= Vector3(slope.x, 0.0, slope.y) * MASS * Ocean.G * 1.5

	velocity += (fh + Vector3.UP * fy) / MASS * delta
	move_and_slide()

	if s == 0.0:
		state = &"AIRBORNE"
	elif moving:
		state = &"SWIMMING"
	elif treading:
		state = &"TREADING"
	else:
		state = &"SINKING"
	if pos.y + 0.4 < water_height:
		breath -= delta / breath_seconds
		if breath <= 0.0:
			drowned.emit()
	else:
		breath = minf(1.0, breath + delta / 3.0)


func _process(delta: float) -> void:
	var lean_target := 0.0
	match state:
		&"SWIMMING": lean_target = 1.25
		&"TREADING": lean_target = 0.15
		&"SINKING": lean_target = 0.35
	_lean = lerpf(_lean, lean_target, minf(1.0, 4.0 * delta))
	model.rotation = Vector3(-_lean, _facing, 0.0) if boat == null else Vector3.ZERO


## Fraction of the body below the given water height.
func submerged(h: float) -> float:
	return clampf((h - (global_position.y - CHEST)) / HEIGHT, 0.0, 1.0)


func head_depth() -> float:
	return water_height - (global_position.y + 0.4)


func respawn(at: Vector3) -> void:
	if boat:
		_leave_boat()
	global_position = at
	velocity = Vector3.ZERO
	breath = 1.0
	_prev_h = NAN


## Displacement source for the ripple sim: a small column, plus kicking.
func ripple_source() -> PackedFloat32Array:
	if boat:
		return PackedFloat32Array()
	var t := Time.get_ticks_msec() / 1000.0
	var kick := 0.0
	match state:
		&"SWIMMING": kick = 0.03 * (1.0 + sin(t * 7.0))
		&"TREADING": kick = 0.012 * (1.0 + sin(t * 9.0))
	var depth := submerged(_swell) * 0.5 + kick
	if depth <= 0.0:
		return PackedFloat32Array()
	return PackedFloat32Array([global_position.x, global_position.z, 0.0, 1.0, 0.45, 0.45, depth, 2.0])


func _try_board() -> void:
	for b: Boat in get_tree().get_nodes_in_group(&"boats"):
		if b.driver == null and global_position.distance_to(b.global_position) < board_range \
				and head_depth() < 1.5:
			boat = b
			b.driver = self
			_collision.disabled = true
			velocity = Vector3.ZERO
			return


func _leave_boat() -> void:
	var b := boat
	boat = null
	b.driver = null
	b.throttle = 0.0
	b.steer = 0.0
	var side := b.global_basis.x
	global_position = b.global_position + side * 2.1 + Vector3.UP * 1.2
	velocity = b.linear_velocity + side * 2.5 + Vector3.UP * 2.5
	_collision.disabled = false
	_prev_h = NAN


func _drive() -> void:
	boat.throttle = Input.get_axis(&"move_back", &"move_forward")
	boat.steer = Input.get_axis(&"move_right", &"move_left")
	global_transform = boat.seat.global_transform
	velocity = boat.linear_velocity
	state = &"ON BOAT"
	breath = 1.0
	water_height = Ocean.instance.height_at(global_position.x, global_position.z) if Ocean.instance else 0.0
