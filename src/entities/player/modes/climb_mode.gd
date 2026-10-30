class_name ClimbMode
extends PlayerMode
## On rock too steep to walk: no gravity; WASD moves up, down and across it
## (relative to the rock, not the camera), Ctrl faster, the chest held 0.45 m
## off it and the body (and its capsule) lying along it, following its turns.
## Little ledges with no room to stand on are climbed past. Where the rock
## ends or turns walkable and you're climbing up: Mantle over the top; with
## nothing to hold, or E: let go (Walk, falling).

const SPEED := 3.0             ## m/s (Ctrl: 1.6 times).
const REACH := 1.4             ## How far ahead rock can be grabbed (m).

var normal := Vector3.BACK     ## The rock's normal where you're holding on.


## Rock to grab in front of a player facing `facing`: its hit (with
## "normal"), or empty.
static func find_hold(p: Player, facing: float) -> Dictionary:
	var face := Basis(Vector3.UP, facing) * Vector3.FORWARD
	for drop: float in [0.0, -0.6, 0.4]:
		var from := p.global_position + Vector3.UP * drop
		var hit := p.ray(from, from + face * REACH)
		if hit and hit.normal.y < Player.CLIMBABLE_Y:
			return hit
	return {}


func enter(_from: StringName, args: Dictionary) -> void:
	normal = args.get("normal", Vector3.BACK)
	player.velocity = Vector3.ZERO
	player.set_water(null)
	player.water_height = -INF
	player.set_head_under(false)
	pose = &"CLIMBING"


func exit() -> void:
	player.reset_collision()


## Let go: the body stands upright again, moved off the rock first so it
## doesn't stand up into it, and falls.
func let_go() -> void:
	var p := player
	p.global_position += normal * maxf(0.0, 1.05 * normal.y - 0.05)
	p.change_mode(&"WALK")
	p.velocity = normal * 1.0   # push off


func physics(delta: float) -> void:
	var p := player
	var hit := p.ray(p.global_position + normal * 0.5, p.global_position - normal * 2.0)
	if not hit.is_empty() and hit.normal.y >= Player.CLIMBABLE_Y and not _can_stand(hit.position):
		# only a little ledge in the rock (no room to stand on it): hold on to
		# the steep rock just above or below it and climb on past it
		for dy: float in [0.6, -0.6, 1.1, -1.1]:
			var o := p.global_position + Vector3.UP * dy
			var h2 := p.ray(o + normal * 0.5, o - normal * 2.0)
			if h2 and h2.normal.y < Player.CLIMBABLE_Y:
				hit = h2
				break
	if hit.is_empty() or hit.normal.y >= Player.CLIMBABLE_Y:
		# the rock ends or turns walkable: pull up onto it (where it turned
		# walkable, or over the top) if you're climbing up, otherwise
		# there's nothing to hold
		var top := Vector3.INF
		if not hit.is_empty():
			if p.intent.move.y <= 0.0:
				p.velocity = Vector3.ZERO   # (just hold on here)
				return
			top = hit.position
		else:
			for reach: float in [0.8, 1.6]:
				var over := p.global_position + Vector3.UP * 1.6 - normal * reach
				var ground := p.ray(over, over + Vector3.DOWN * 3.5)
				if ground and ground.normal.y >= Player.CLIMBABLE_Y:
					top = ground.position
					break
		if top != Vector3.INF:
			p.change_mode(&"MANTLE", {"to": top + Vector3.UP * (Player.CHEST + 0.05), "normal": normal})
		else:
			let_go()
		return
	normal = normal.slerp(hit.normal, minf(1.0, 10.0 * delta)).normalized()
	var up_dir := (Vector3.UP - normal * Vector3.UP.dot(normal)).normalized()
	var right_dir := up_dir.cross(normal).normalized()
	var speed := SPEED * (1.6 if p.intent.sprint else 1.0)
	var move := (up_dir * p.intent.move.y + right_dir * p.intent.move.x).limit_length(1.0) * speed
	var off: float = (p.global_position - (hit.position as Vector3)).dot(normal)
	p.velocity = move + normal * (0.45 - off) * 8.0
	p.lie_along(normal)
	p.move_and_slide()


func input(event: InputEvent) -> bool:
	if event.is_action_pressed(&"climb"):
		let_go()
		return true
	return false


func orient(_delta: float) -> void:
	player.face_rock(normal)


# Whether there's room to stand at p: walkable ground there and a little
# further in from the rock's edge, and space above it for the body.
func _can_stand(at: Vector3) -> bool:
	var p := player
	var inward := Vector3(-normal.x, 0.0, -normal.z)
	inward = inward.normalized() if inward.length() > 0.01 else Vector3.ZERO
	var g := p.ray(at + inward * 0.5 + Vector3.UP * 1.0, at + inward * 0.5 + Vector3.DOWN * 0.6)
	if g.is_empty() or g.normal.y < Player.CLIMBABLE_Y:
		return false
	return p.body_fits(at + inward * 0.3 + Vector3.UP * (Player.HEIGHT * 0.5 + 0.1))
