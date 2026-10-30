class_name Player
extends Character
## The player's body. How it moves is up to its active mode (PlayerMode:
## WalkMode, SwimMode, ClimbMode, MantleMode, DriveMode, FlyMode), one at a
## time; `state` is the active mode's id and `pose` what the body is doing
## within it. Each mode decides when to hand over to the next. The modes act
## on an intent (PlayerIntent, read from the keyboard and mouse each physics
## frame, or nothing while `input_locked`), never on Input directly.
##
## Breath and drowning are PlayerStats' (the body's condition and its
## records). Carries three inventories: one per hand and a knapsack; gear that
## changes abilities (a snorkel, a scuba tank) is read through gear_stat().
## The body (CharacterRig) is animated procedurally for every pose.

const MASS := 75.0
const HEIGHT := 1.7
const CHEST := 1.3                          ## Feet are this far below the origin (chest).
const VOLUME := 0.97 * MASS / Water.RHO_SEA ## 3% denser than seawater.
const LAND_GRAVITY := 9.8                   ## Real gravity (m/s^2)
const FALL_GRAVITY := 2.2                   ## Gravity is this many times stronger coming down (no floating down mountains; jumps rise as before).
const JUMP_CARRY := 15.0                    ## A jump keeps at most this much of your speed across the ground (m/s).
const CLIMBABLE_Y := 0.72                   ## Ground steeper than this (normal.y below it, ~44 deg) can't be walked: it's climbed.
const SAVED_TRAITS := "user://player_traits.tres"   ## The look chosen in the character picker.

@export var board_range := 5.0
@export var walk_speed := 20.0              ## m/s on land
@export var jump_speed := 4.95              ## About a 1.25 m hop under land gravity
@export var traits: CharacterTraits

## The active mode's id: WALK, SWIM, CLIMB, MANTLE, DRIVE or FLY (and
## `pose`, inherited, what the body is doing within it).
var state: StringName:
	get:
		return mode.id if mode else &""
var mode: PlayerMode
var intent := PlayerIntent.new()
var water_height := -INF  ## Surface height here, including ripples (-INF on land).
var water: WaterBody      ## The body the player is in or over (null on land).
var boat: Boat            ## Set while driving.
var input_locked := false ## No control (the character picker is open); the body faces `locked_facing`.
var locked_facing := 0.0

## On the rock (climbing or pulling up over its top).
var climbing: bool:
	get:
		return state == &"CLIMB" or state == &"MANTLE"
## In debug flight; setting it takes off or lands.
var flying: bool:
	get:
		return state == &"FLY"
	set(on):
		if on and state != &"FLY":
			change_mode(&"FLY")
		elif not on and state == &"FLY":
			change_mode(&"WALK")
			velocity = Vector3.ZERO   # stop dead and fall from rest, not carried on by the flight
var modes := {}

@onready var left_hand: Inventory = $LeftHand
@onready var right_hand: Inventory = $RightHand
@onready var knapsack: Inventory = $Knapsack
@onready var stats: PlayerStats = $Stats
@onready var _collision: CollisionShape3D = $Collision
@onready var _collision_rest := _collision.transform

var _lean := 0.0
var _facing := 0.0
var _last_space := -10.0


func _ready() -> void:
	add_to_group(&"ripple_sources")
	floor_snap_length = 1.2   # stay on the ground running downhill
	for m: PlayerMode in [WalkMode.new(self, &"WALK"), SwimMode.new(self, &"SWIM"), ClimbMode.new(self, &"CLIMB"),
			MantleMode.new(self, &"MANTLE"), DriveMode.new(self, &"DRIVE"), FlyMode.new(self, &"FLY")]:
		modes[m.id] = m
	change_mode(&"WALK")
	var rig := CharacterRig.new()
	rig.name = "Rig"
	rig.body = self
	add_child(rig)
	rig.build()
	if FileAccess.file_exists(SAVED_TRAITS):   # (the look chosen last time, over the default)
		var saved := load(SAVED_TRAITS) as CharacterTraits
		if saved:
			traits = saved
	if traits == null:
		traits = CharacterTraits.new()
	traits.apply_to(model)
	var game := WorldConfig._game()
	if game:
		game.player = self


## Hand over to another mode (with whatever it needs to start: `args`).
func change_mode(id: StringName, args := {}) -> void:
	var from := state
	if mode:
		mode.exit()
	mode = modes[id]
	mode.enter(from, args)
	pose = mode.pose
	if from != id:
		emit_event(&"player_mode_changed", [id])


func _physics_process(delta: float) -> void:
	intent = PlayerIntent.read(input_locked)
	mode.physics(delta)
	# (for the rig and the HUD: what the body is doing, as its mode says)
	pose = mode.pose
	climb_normal = (modes[&"CLIMB"] as ClimbMode).normal


func _unhandled_input(event: InputEvent) -> void:
	if input_locked:
		return
	# double-tap Space: fly (debug), like Minecraft's creative mode
	if event.is_action_pressed(&"tread") and not event.is_echo() and state != &"DRIVE":
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_space < 0.3:
			flying = not flying
			_last_space = -10.0
		else:
			_last_space = now
	# Minecraft-style: right-click boards (Shift dismounts: DriveMode)
	if event.is_action_pressed(&"interact") and (state == &"WALK" or state == &"SWIM"):
		try_board()
	mode.input(event)


func _process(delta: float) -> void:
	if input_locked:
		_facing = locked_facing
		_lean = 0.0
		model.rotation = Vector3(0.0, _facing, 0.0)
		return
	mode.orient(delta)


## Grab the rock in front if it's too steep to walk on (Climb). True if so.
func try_climb() -> bool:
	var hit := ClimbMode.find_hold(self, _facing)
	if hit.is_empty():
		return false
	change_mode(&"CLIMB", {"normal": hit.normal})
	return true


## Take the helm of a free boat within reach (Drive). True if so.
func try_board() -> bool:
	for b: Boat in get_tree().get_nodes_in_group(&"boats"):
		if b.driver == null and global_position.distance_to(b.global_position) < board_range and head_depth() < 1.5:
			change_mode(&"DRIVE", {"boat": b})
			return true
	return false


func respawn(at: Vector3) -> void:
	change_mode(&"WALK")
	global_position = at
	velocity = Vector3.ZERO
	stats.refill_breath()


# --- for the modes ------------------------------------------------------------------

## Turn the body to where the camera looks, leaning forward by `lean` (rad).
func face_camera(delta: float, lean: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam:
		var look := -cam.global_basis.z
		if Vector2(look.x, look.z).length() > 0.01:
			_facing = atan2(-look.x, -look.z)
	_lean = lerpf(_lean, lean, minf(1.0, 4.0 * delta))
	model.rotation = Vector3(-_lean, _facing, 0.0)


## Aboard: the body turns to the camera, relative to the boat it rides.
func face_camera_aboard(b: Boat) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam:
		var look := -cam.global_basis.z
		if Vector2(look.x, look.z).length() > 0.01:
			_facing = atan2(-look.x, -look.z)
	var fwd := -b.global_basis.z
	_lean = 0.0
	model.rotation = Vector3(0.0, angle_difference(atan2(-fwd.x, -fwd.z), _facing), 0.0)


## On the rock: the body faces it, lying parallel to it.
func face_rock(n: Vector3) -> void:
	_facing = atan2(n.x, n.z)
	_lean = 0.0
	model.rotation = Vector3(-asin(clampf(n.y, -0.9, 0.9)), _facing, 0.0)


## The capsule lies along rock with normal n (not upright into it).
func lie_along(n: Vector3) -> void:
	var lie := Basis.from_euler(Vector3(-asin(clampf(n.y, -0.9, 0.9)), atan2(n.x, n.z), 0.0))
	_collision.transform = Transform3D(lie, lie * _collision_rest.origin)


func reset_collision() -> void:
	_collision.transform = _collision_rest


func set_collision_enabled(on: bool) -> void:
	_collision.disabled = not on


## Whether the body's capsule, upright with its centre at `centre`, fits there.
func body_fits(centre: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _collision.shape
	q.transform = Transform3D(Basis(), centre)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


## A strafe/forward input turned into a direction across the ground,
## relative to the camera's heading.
func camera_relative(input: Vector2) -> Vector2:
	var cam := get_viewport().get_camera_3d()
	if cam == null or input == Vector2.ZERO:
		return Vector2.ZERO
	var fwd := -cam.global_basis.z
	var right := cam.global_basis.x
	var f := Vector2(fwd.x, fwd.z).normalized()
	var r := Vector2(right.x, right.z).normalized()
	return (f * input.y + r * input.x).limit_length(1.0)


func set_water(body: WaterBody) -> void:
	if body != water:
		water = body
		emit_event(&"player_water_changed", [body])


func set_head_under(under: bool) -> void:
	if under != head_under:
		head_under = under
		emit_event(&"player_submerged_changed", [under])


func emit_event(signal_name: StringName, args := []) -> void:
	var events := get_node_or_null(^"/root/Events")
	if events:
		events.emit_signal.callv([signal_name] + args)


# --- queries ------------------------------------------------------------------------

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


## Displacement source for the ripple sim: a small column, plus kicking.
func ripple_source() -> PackedFloat32Array:
	if state != &"SWIM":
		return PackedFloat32Array()
	var t := Time.get_ticks_msec() / 1000.0
	var kick := 0.0
	match pose:
		&"SWIMMING": kick = 0.03 * (1.0 + sin(t * 7.0))
		&"TREADING": kick = 0.012 * (1.0 + sin(t * 9.0))
	var depth := submerged((mode as SwimMode).swell()) * 0.5 + kick
	if depth <= 0.0:
		return PackedFloat32Array()
	return PackedFloat32Array([global_position.x, global_position.z, 0.0, 1.0, 0.45, 0.45, depth, 2.0])
