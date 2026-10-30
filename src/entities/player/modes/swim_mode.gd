class_name SwimMode
extends PlayerMode
## In (or over) water: one buoyancy probe at the chest, slightly denser than
## the water, so doing nothing means sinking; treading and swimming are
## force-limited kicks toward the surface. Forward follows the camera's pitch
## (look down to dive), Space swims up, Shift down; rivers carry you along
## and wakes shove you. In the shallows with your feet down you wade. Out of
## all water: Walk. E on steep rock: Climb.

const SWIM_FORCE := 260.0      ## N
const SPRINT := 1.6            ## Ctrl.

var _swell := 0.0
var _prev_h := NAN


func enter(_from: StringName, _args: Dictionary) -> void:
	player.reset_collision()
	_prev_h = NAN


## The swell's height here (for the ripples the body makes).
func swell() -> float:
	return _swell


func physics(delta: float) -> void:
	var p := player
	var pos := p.global_position
	var body := Water.body_at(pos.x, pos.z)
	if body == null:
		p.change_mode(&"WALK")
		p.mode.physics(delta)
		return
	p.set_water(body)
	_swell = body.surface_height(pos.x, pos.z, 0.5)
	p.water_height = _swell + body.ripple_height(pos.x, pos.z, 0.8)
	var water_vy := 0.0 if is_nan(_prev_h) else (p.water_height - _prev_h) / delta
	_prev_h = p.water_height
	var s := p.submerged(p.water_height)
	var vrel := p.velocity.y - water_vy
	var it := p.intent
	var move := Vector3.ZERO
	var cam := p.get_viewport().get_camera_3d()
	if cam and (it.move != Vector2.ZERO or it.rise != 0.0):
		var fwd := -cam.global_basis.z
		var right := cam.global_basis.x
		right.y = 0.0
		move = fwd.normalized() * it.move.y + right.normalized() * it.move.x + Vector3.UP * it.rise
		if move.length() > 1.0:
			move = move.normalized()
	var treading := it.jump
	var moving := move != Vector3.ZERO
	var deep := pos.y + 0.4 < p.water_height - 0.8   # head well under: free 3D swimming
	var sprint := SPRINT if it.sprint and it.move.y > 0.0 else 1.0

	var fy := -Player.MASS * Water.G + body.density() * Water.G * Player.VOLUME * s
	if s > 0.0:
		fy -= (40.0 + 60.0 * absf(vrel)) * vrel
		# at the surface, swimming level or treading keeps the head up; aiming
		# down (or pressing Shift) lets you dive under instead
		if not deep and (treading or (moving and move.y > -0.3)):
			# kicking is a one-sided, force-limited spring toward the surface
			var target := p.water_height + (0.15 if treading else -0.1)
			var lift_max := (0.30 if treading else 0.22) * Player.MASS * Water.G
			fy += clampf(1500.0 * (target - pos.y) - 400.0 * vrel, 0.0, lift_max)
	var fh := Vector3.ZERO
	if s > 0.2:
		if moving:
			fh = Vector3(move.x, 0.0, move.z) * SWIM_FORCE * sprint
			if deep or move.y < -0.3:
				fy += move.y * SWIM_FORCE * sprint   # pitch and Shift/Space steer depth
		var vh := Vector3(p.velocity.x, 0.0, p.velocity.z) - body.flow_at(pos.x, pos.z)   # rivers carry you along
		fh -= (30.0 + 70.0 * vh.length()) * vh
		if pos.y + 0.4 > p.water_height - 0.5:   # near the surface: wakes shove you
			var slope := body.ripple_slope(pos.x, pos.z)
			fh -= Vector3(slope.x, 0.0, slope.y) * Player.MASS * Water.G * 1.5
	p.velocity += (fh + Vector3.UP * fy) / Player.MASS * delta
	var wading := s < 0.3 and p.is_on_floor()
	if wading:
		WalkMode.walk(p, delta, true)
	p.move_and_slide()
	if wading:
		pose = &"WALKING"
	elif s == 0.0:
		pose = &"AIRBORNE"
	elif moving and deep:
		pose = &"DIVING"
	elif moving:
		pose = &"SWIMMING"
	elif treading:
		pose = &"TREADING"
	else:
		pose = &"SINKING"
	p.set_head_under(pos.y + 0.4 < p.water_height)


func input(event: InputEvent) -> bool:
	if event.is_action_pressed(&"climb"):
		return player.try_climb()
	return false


func orient(delta: float) -> void:
	var lean := 0.0
	match pose:
		&"SWIMMING": lean = 1.25
		&"TREADING": lean = 0.15
		&"SINKING": lean = 0.35
	player.face_camera(delta, lean)
