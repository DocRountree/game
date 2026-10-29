class_name Player
extends CharacterBody3D
## Swimmer with one buoyancy probe at the chest. Slightly denser than water, so
## doing nothing means sinking; treading and swimming are force-limited kicks
## toward the surface. Can board and drive a Boat.
##
## Carries three inventories: one per hand and a knapsack. Equipment that
## changes abilities (snorkel, scuba tank) is read through gear_stat(), so
## breath, depth limits and the like stay data-driven.
##
## E grabs ground too steep to walk on (if there is some in front of you) and
## climbs it: WASD moves up, down and across the rock, you pull yourself over
## the top when it turns walkable, and E lets go. The body (CharacterRig) is
## animated procedurally for every state.

signal drowned

const MASS := 75.0
const HEIGHT := 1.7
const CHEST := 1.3                          ## Feet are this far below the origin (chest).
const VOLUME := 0.97 * MASS / Water.RHO_SEA ## 3% denser than seawater.

@export var swim_force := 260.0             ## N
@export var breath_seconds := 20.0          ## Breath-hold without gear.
@export var board_range := 5.0
@export var sprint_factor := 1.6           ## Ctrl: faster swimming
@export var walk_speed := 20.0              ## m/s on land
@export var run_factor := 1.3               ## Ctrl on land (Minecraft's sprint)
@export var jump_speed := 4.95              ## About a 1.25 m hop under land gravity
@export var fly_speed := 120.0              ## Debug flight (double-tap Space)
@export var climb_speed := 3.0              ## m/s on rock (Ctrl: faster)

const LAND_GRAVITY := 9.8                   ## Real gravity (m/s^2)
const MANTLE_TIME := 0.45                   ## s to pull up over the top of a climb.
const MANTLE_SETTLE := 1.0                  ## s of slower walking after pulling up (no stepping straight off the edge).
const JUMP_CARRY := 15.0                    ## A jump keeps at most this much of your speed across the ground (m/s).
const FALL_GRAVITY := 2.2                   ## Gravity is this many times stronger coming down (no floating down mountains; jumps rise as before).
const CLIMBABLE_Y := 0.72                   ## Ground steeper than this (normal.y below it, ~44 deg) can't be walked: it's climbed.
@export var traits: CharacterTraits

var state := &"TREADING"
var breath := 1.0
var water_height := 0.0   ## Surface height here, including ripples (-INF on land).
var water: WaterBody      ## The body the player is in or over (null on land).
var boat: Boat            ## Set while driving.
var head_under := false   ## Head below the surface (snorkels, scuba, the camera's underwater look).
var flying := false       ## Debug flight, toggled by double-tapping Space.
var climbing := false     ## On the rock (E).
var climb_normal := Vector3.BACK   ## The rock's normal where you're holding on.
var _mantle_t := -1.0              ## Progress pulling up over the top (-1: not).
var _mantle_from := Vector3.ZERO
var _mantle_to := Vector3.ZERO
var _settle := 0.0                 ## Time left walking slowly after a mantle.

@onready var left_hand: Inventory = $LeftHand
@onready var right_hand: Inventory = $RightHand
@onready var knapsack: Inventory = $Knapsack
@onready var stats: PlayerStats = $Stats

var _swell := 0.0
var _prev_h := NAN
var _lean := 0.0
var _facing := 0.0
var _last_space := -10.0

@onready var model: Node3D = $Model
@onready var _collision: CollisionShape3D = $Collision
@onready var _collision_rest := _collision.transform


func _ready() -> void:
	add_to_group(&"ripple_sources")
	floor_snap_length = 1.2   # stay on the ground running downhill
	var rig := CharacterRig.new()
	rig.name = "Rig"
	rig.player = self
	add_child(rig)
	rig.build()
	if traits:
		traits.apply_to(model)
	var game := WorldConfig._game()
	if game:
		game.player = self


func _unhandled_input(event: InputEvent) -> void:
	# double-tap Space: fly (debug), like Minecraft's creative mode
	if event.is_action_pressed(&"tread") and not event.is_echo() and not boat:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_space < 0.3:
			flying = not flying
			let_go()
			if not flying:
				velocity = Vector3.ZERO   # stop dead and fall from rest, not carried on by the flight
			_last_space = -10.0
		else:
			_last_space = now
	if event.is_action_pressed(&"climb") and not boat and not flying:
		if climbing:
			if _mantle_t < 0.0:
				let_go()
		else:
			try_climb()
	# Minecraft-style: right-click boards, Shift dismounts
	if event.is_action_pressed(&"interact") and not boat:
		_try_board()
	elif event.is_action_pressed(&"dive") and boat:
		_leave_boat()


func _physics_process(delta: float) -> void:
	if boat:
		_drive()
		return
	var pos := global_position
	if flying:
		_fly(delta)
		return
	if climbing:
		_climb(delta)
		return
	_collision.transform = _collision_rest
	_set_water(Water.body_at(pos.x, pos.z))
	if water == null:
		_on_land(delta)
		return
	_swell = water.surface_height(pos.x, pos.z, 0.5)
	water_height = _swell + water.ripple_height(pos.x, pos.z, 0.8)
	var water_vy := 0.0 if is_nan(_prev_h) else (water_height - _prev_h) / delta
	_prev_h = water_height
	var s := submerged(water_height)
	var vrel := velocity.y - water_vy

	# 3D swimming: forward follows the camera's pitch, so look down to dive and
	# up to climb; Space swims straight up, Shift straight down
	var cam := get_viewport().get_camera_3d()
	var input := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	var rise := Input.get_axis(&"dive", &"tread")
	var move := Vector3.ZERO
	if cam and (input != Vector2.ZERO or rise != 0.0):
		var fwd := -cam.global_basis.z
		var right := cam.global_basis.x
		right.y = 0.0
		move = fwd.normalized() * input.y + right.normalized() * input.x + Vector3.UP * rise
		if move.length() > 1.0:
			move = move.normalized()
	var treading := Input.is_action_pressed(&"tread")
	var moving := move != Vector3.ZERO
	var deep := pos.y + 0.4 < water_height - 0.8   # head well under: free 3D swimming
	var sprint := sprint_factor if Input.is_action_pressed(&"sprint") and input.y > 0.0 else 1.0

	var fy := -MASS * Water.G + water.density() * Water.G * VOLUME * s
	if s > 0.0:
		fy -= (40.0 + 60.0 * absf(vrel)) * vrel
		# at the surface, swimming level or treading keeps the head up; aiming
		# down (or pressing Shift) lets you dive under instead
		var surface_swim := not deep and (treading or (moving and move.y > -0.3))
		if surface_swim:
			# kicking is a one-sided, force-limited spring toward the surface
			var target := water_height + (0.15 if treading else -0.1)
			var lift_max := (0.30 if treading else 0.22) * MASS * Water.G
			fy += clampf(1500.0 * (target - pos.y) - 400.0 * vrel, 0.0, lift_max)

	var fh := Vector3.ZERO
	if s > 0.2:
		if moving:
			fh = Vector3(move.x, 0.0, move.z) * swim_force * sprint
			if deep or move.y < -0.3:
				fy += move.y * swim_force * sprint   # pitch and Shift/Space steer depth
		var vh := Vector3(velocity.x, 0.0, velocity.z) - water.flow_at(pos.x, pos.z)   # rivers carry you along
		fh -= (30.0 + 70.0 * vh.length()) * vh
		if pos.y + 0.4 > water_height - 0.5:   # near the surface: wakes shove you
			var slope := water.ripple_slope(pos.x, pos.z)
			fh -= Vector3(slope.x, 0.0, slope.y) * MASS * Water.G * 1.5

	velocity += (fh + Vector3.UP * fy) / MASS * delta
	if s < 0.3 and is_on_floor():
		_walk(delta, true)   # wading in the shallows
	move_and_slide()

	if s < 0.3 and is_on_floor():
		state = &"WALKING"
	elif s == 0.0:
		state = &"AIRBORNE"
	elif moving and deep:
		state = &"DIVING"
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


# Dry land: gravity, walking and jumping.
func _on_land(delta: float) -> void:
	water_height = -INF
	_prev_h = NAN
	velocity.y -= LAND_GRAVITY * delta * (FALL_GRAVITY if velocity.y < 0.0 else 1.0)
	_settle = maxf(_settle - delta, 0.0)
	_walk(delta, is_on_floor())
	move_and_slide()
	# never under the ground (if something ever pushes the body through the
	# collider, it's put back on top rather than falling into the void)
	if Terrain.current():
		var g := Terrain.height_at(global_position.x, global_position.z)
		if global_position.y - CHEST < g - 0.6:
			global_position.y = g + CHEST
			velocity.y = maxf(velocity.y, 0.0)
	state = &"WALKING" if is_on_floor() else &"AIRBORNE"
	_set_head_under(false)
	breath = minf(1.0, breath + delta / 3.0)


# Minecraft-style: WASD relative to the camera's heading, quick to start and
# stop on the ground, little control in the air (momentum carries a jump).
# Ctrl runs, Shift sneaks, holding Space jumps whenever your feet touch down.
func _walk(delta: float, grounded: bool) -> void:
	var wish := _camera_relative(Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward"))
	var speed := walk_speed
	if Input.is_action_pressed(&"sprint") and Input.get_axis(&"move_back", &"move_forward") > 0.0:
		speed *= run_factor
	if Input.is_action_pressed(&"dive"):
		speed *= 0.3
	speed *= lerpf(1.0, 0.3, _settle / MANTLE_SETTLE)   # (just after pulling up over an edge)
	var target := wish * speed
	var vh := Vector2(velocity.x, velocity.z)
	var rate := 18.0 if grounded else (2.0 if wish != Vector2.ZERO else 0.1)
	vh = vh.lerp(target, 1.0 - exp(-rate * delta))
	# the faster you run, the harder you keep to the ground (running over a
	# crest or down a slope doesn't throw you into the air)
	floor_snap_length = 1.2 + 0.08 * vh.length()
	if grounded and Input.is_action_pressed(&"tread"):
		velocity.y = jump_speed
		vh = vh.limit_length(JUMP_CARRY)   # (a running jump carries you no further than a brisk one)
	velocity.x = vh.x
	velocity.z = vh.y


# Debug flight: no gravity, Space up, Shift down, Ctrl faster. Touching the
# ground while descending lands you.
func _fly(delta: float) -> void:
	var wish := _camera_relative(Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward"))
	var up := Input.get_axis(&"dive", &"tread")
	var speed := fly_speed * (3.0 if Input.is_action_pressed(&"sprint") else 1.0)
	var target := Vector3(wish.x, up, wish.y) * speed
	velocity = velocity.lerp(target, 1.0 - exp(-6.0 * delta))
	move_and_slide()
	if is_on_floor() and up < 0.0:
		flying = false
		velocity = Vector3.ZERO
	state = &"FLYING"
	water_height = -INF
	_set_head_under(false)
	breath = 1.0


## Grab the rock in front of you if it's too steep to walk on. True if you did.
func try_climb() -> bool:
	var face := Basis(Vector3.UP, _facing) * Vector3.FORWARD
	for drop: float in [0.0, -0.6, 0.4]:
		var from := global_position + Vector3.UP * drop
		var hit := _ray(from, from + face * 1.4)
		if hit and hit.normal.y < CLIMBABLE_Y:
			climbing = true
			climb_normal = hit.normal
			velocity = Vector3.ZERO
			_set_water(null)
			return true
	return false


# On the rock: no gravity; WASD moves up, down and across it (relative to the
# rock, not the camera), the body held a little off it, following its turns.
func _climb(delta: float) -> void:
	state = &"CLIMBING"
	water_height = -INF
	_set_head_under(false)
	breath = minf(1.0, breath + delta / 3.0)
	var hit := _ray(global_position + climb_normal * 0.5, global_position - climb_normal * 2.0)
	if _mantle_t >= 0.0:
		_mantle(delta)
		return
	if not hit.is_empty() and hit.normal.y >= CLIMBABLE_Y and not _can_stand(hit.position):
		# only a little ledge in the rock (no room to stand on it): hold on to
		# the steep rock just above or below it and climb on past it
		for dy: float in [0.6, -0.6, 1.1, -1.1]:
			var o := global_position + Vector3.UP * dy
			var h2 := _ray(o + climb_normal * 0.5, o - climb_normal * 2.0)
			if h2 and h2.normal.y < CLIMBABLE_Y:
				hit = h2
				break
	if hit.is_empty() or hit.normal.y >= CLIMBABLE_Y:
		# the rock ends or turns walkable: pull up onto it (where it turned
		# walkable, or over the top) if you're climbing up, otherwise
		# there's nothing to hold
		var top := Vector3.INF
		if not hit.is_empty():
			if Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward").y <= 0.0:
				velocity = Vector3.ZERO   # (just hold on here)
				return
			top = hit.position
		else:
			for reach: float in [0.8, 1.6]:
				var over := global_position + Vector3.UP * 1.6 - climb_normal * reach
				var ground := _ray(over, over + Vector3.DOWN * 3.5)
				if ground and ground.normal.y >= CLIMBABLE_Y:
					top = ground.position
					break
		if top != Vector3.INF:
			_mantle_from = global_position
			_mantle_to = top + Vector3.UP * (CHEST + 0.05)
			_mantle_t = 0.0
			_collision.disabled = true   # (the body passes over the edge)
		else:
			let_go()
		return
	climb_normal = climb_normal.slerp(hit.normal, minf(1.0, 10.0 * delta)).normalized()
	var up_dir := (Vector3.UP - climb_normal * Vector3.UP.dot(climb_normal)).normalized()
	var right_dir := up_dir.cross(climb_normal).normalized()
	var input := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	var speed := climb_speed * (1.6 if Input.is_action_pressed(&"sprint") else 1.0)
	var move := (up_dir * input.y + right_dir * input.x).limit_length(1.0) * speed
	# hold the chest about 0.45 m off the rock
	var off: float = (global_position - (hit.position as Vector3)).dot(climb_normal)
	velocity = move + climb_normal * (0.45 - off) * 8.0
	# the body (and its capsule) lies along the rock, not upright into it
	var lie := Basis.from_euler(Vector3(-asin(clampf(climb_normal.y, -0.9, 0.9)), atan2(climb_normal.x, climb_normal.z), 0.0))
	_collision.transform = Transform3D(lie, lie * _collision_rest.origin)
	move_and_slide()


# Pulling up over the top: up first, then over onto the ground, standing.
func _mantle(delta: float) -> void:
	_mantle_t = minf(_mantle_t + delta / MANTLE_TIME, 1.0)
	var t := _mantle_t
	var p := _mantle_from.lerp(_mantle_to, t * t)
	p.y = lerpf(_mantle_from.y, _mantle_to.y, 1.0 - (1.0 - t) * (1.0 - t)) + sin(PI * t) * 0.25
	global_position = p
	velocity = Vector3.ZERO
	if _mantle_t >= 1.0:
		_mantle_t = -1.0
		climbing = false
		_collision.disabled = false
		_collision.transform = _collision_rest
		var on := Vector3(-climb_normal.x, 0.0, -climb_normal.z)
		velocity = on.normalized() * 1.0 if on.length() > 0.01 else Vector3.ZERO
		_settle = MANTLE_SETTLE


## Let go of the rock: the body stands upright again, moved off the rock first
## so it doesn't stand up into it, and falls.
func let_go() -> void:
	if not climbing:
		return
	climbing = false
	_mantle_t = -1.0
	_collision.disabled = false
	global_position += climb_normal * maxf(0.0, 1.05 * climb_normal.y - 0.05)
	_collision.transform = _collision_rest
	velocity = climb_normal * 1.0   # push off


# Whether there's room to stand at p: walkable ground there and a little
# further in from the rock's edge, and space above it for the body.
func _can_stand(p: Vector3) -> bool:
	var inward := Vector3(-climb_normal.x, 0.0, -climb_normal.z)
	inward = inward.normalized() if inward.length() > 0.01 else Vector3.ZERO
	var g := _ray(p + inward * 0.5 + Vector3.UP * 1.0, p + inward * 0.5 + Vector3.DOWN * 0.6)
	if g.is_empty() or g.normal.y < CLIMBABLE_Y:
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = (_collision.shape as CapsuleShape3D)
	q.transform = Transform3D(Basis(), p + inward * 0.3 + Vector3.UP * (HEIGHT * 0.5 + 0.1))
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


func _camera_relative(input: Vector2) -> Vector2:
	var cam := get_viewport().get_camera_3d()
	if cam == null or input == Vector2.ZERO:
		return Vector2.ZERO
	var fwd := -cam.global_basis.z
	var right := cam.global_basis.x
	var f := Vector2(fwd.x, fwd.z).normalized()
	var r := Vector2(right.x, right.z).normalized()
	return (f * input.y + r * input.x).limit_length(1.0)


func _process(delta: float) -> void:
	# face where the camera looks; aboard, only the body turns, not the boat
	var cam := get_viewport().get_camera_3d()
	if climbing:
		# face the rock, the body parallel to it
		_facing = atan2(climb_normal.x, climb_normal.z)
		model.rotation = Vector3(-asin(clampf(climb_normal.y, -0.9, 0.9)), _facing, 0.0)
		_lean = 0.0
		return
	if cam:
		var look := -cam.global_basis.z
		if Vector2(look.x, look.z).length() > 0.01:
			_facing = atan2(-look.x, -look.z)
	var lean_target := 0.0
	match state:
		&"SWIMMING": lean_target = 1.25
		&"TREADING": lean_target = 0.15
		&"SINKING": lean_target = 0.35
	_lean = lerpf(_lean, lean_target, minf(1.0, 4.0 * delta))
	if boat:
		var fwd := -boat.global_basis.z
		model.rotation = Vector3(0.0, angle_difference(atan2(-fwd.x, -fwd.z), _facing), 0.0)
	else:
		model.rotation = Vector3(-_lean, _facing, 0.0)


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
	let_go()
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
			let_go()
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
