class_name Player
extends CharacterBody3D
## Swimmer with one buoyancy probe at the chest. Slightly denser than water, so
## doing nothing means sinking; treading and swimming are force-limited kicks
## toward the surface. Can board and drive a Boat.
##
## Carries three inventories: one per hand and a knapsack. Equipment that
## changes abilities (snorkel, scuba tank) is read through gear_stat(), so
## breath, depth limits and the like stay data-driven.

signal drowned

const MASS := 75.0
const HEIGHT := 1.7
const CHEST := 1.3                          ## Feet are this far below the origin (chest).
const VOLUME := 0.97 * MASS / Water.RHO_SEA ## 3% denser than seawater.

@export var swim_force := 260.0             ## N
@export var breath_seconds := 20.0          ## Breath-hold without gear.
@export var board_range := 5.0
@export var traits: CharacterTraits

var state := &"TREADING"
var breath := 1.0
var water_height := 0.0   ## Surface height here, including ripples (-INF on land).
var water: WaterBody      ## The body the player is in or over (null on land).
var boat: Boat            ## Set while driving.
var head_under := false   ## Head below the surface (snorkels, scuba, the camera's underwater look).

@onready var left_hand: Inventory = $LeftHand
@onready var right_hand: Inventory = $RightHand
@onready var knapsack: Inventory = $Knapsack
@onready var stats: PlayerStats = $Stats

var _swell := 0.0
var _prev_h := NAN
var _lean := 0.0
var _facing := 0.0

@onready var model: Node3D = $Model
@onready var _collision: CollisionShape3D = $Collision


func _ready() -> void:
	add_to_group(&"ripple_sources")
	if traits:
		traits.apply_to(model)
	var game := WorldConfig._game()
	if game:
		game.player = self


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
	var pos := global_position
	_set_water(Water.body_at(pos.x, pos.z))
	if water == null:
		return   # dry land comes with terrain
	_swell = water.surface_height(pos.x, pos.z, 0.5)
	water_height = _swell + water.ripple_height(pos.x, pos.z, 0.8)
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

	var fy := -MASS * Water.G + water.density() * Water.G * VOLUME * s
	if s > 0.0:
		fy -= 40.0 * vrel + 60.0 * vrel * absf(vrel)
		if treading or moving:
			# kicking is a one-sided, force-limited spring toward the surface
			var target := water_height + (0.15 if treading else -0.1)
			var lift_max := (0.30 if treading else 0.22) * MASS * Water.G
			fy += clampf(1500.0 * (target - pos.y) - 400.0 * vrel, 0.0, lift_max)

	var fh := Vector3.ZERO
	if s > 0.2:
		if moving:
			fh = move * swim_force
			_facing = atan2(-move.x, -move.z)
		var vh := Vector3(velocity.x, 0.0, velocity.z)
		fh -= (30.0 + 70.0 * vh.length()) * vh
		if pos.y + 0.4 > water_height - 0.5:   # near the surface: wakes shove you
			var slope := water.ripple_slope(pos.x, pos.z)
			fh -= Vector3(slope.x, 0.0, slope.y) * MASS * Water.G * 1.5

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
	_set_head_under(pos.y + 0.4 < water_height)
	if head_under:
		breath -= delta / breath_capacity()
		if breath <= 0.0:
			drowned.emit()
			_emit_event(&"player_drowned")
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


## Seconds of air: breath-hold plus whatever held or worn gear adds.
func breath_capacity() -> float:
	return breath_seconds + gear_stat(&"breath_seconds")


## Sum of a stat over equipped gear (both hands for now; worn gear later).
func gear_stat(stat: StringName) -> float:
	var total := 0.0
	for hand: Inventory in [left_hand, right_hand]:
		for s in hand.items():
			total += s.item.stat(stat)
	return total


## The stack in a hand (0 = left, 1 = right), or null.
func held(hand: int) -> ItemStack:
	var inv := left_hand if hand == 0 else right_hand
	return inv.slots[0]


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
			b.helm.occupant = self
			_set_head_under(false)
			_emit_event(&"boat_boarded", [b, true])
			_collision.disabled = true
			velocity = Vector3.ZERO
			return


func _leave_boat() -> void:
	var b := boat
	boat = null
	b.driver = null
	b.helm.occupant = null
	_emit_event(&"boat_boarded", [b, false])
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
	global_transform = boat.helm.global_transform
	velocity = boat.linear_velocity
	state = &"ON BOAT"
	breath = 1.0
	_set_water(Water.body_at(global_position.x, global_position.z))
	water_height = Water.surface_height(global_position.x, global_position.z)


func _set_water(body: WaterBody) -> void:
	if body != water:
		water = body
		_emit_event(&"player_water_changed", [body])


func _set_head_under(under: bool) -> void:
	if under != head_under:
		head_under = under
		_emit_event(&"player_submerged_changed", [under])


func _emit_event(signal_name: StringName, args := []) -> void:
	var events := get_node_or_null(^"/root/Events")
	if events:
		events.emit_signal.callv([signal_name] + args)
