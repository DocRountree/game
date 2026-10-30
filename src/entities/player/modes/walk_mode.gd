class_name WalkMode
extends PlayerMode
## On dry land: gravity, walking and jumping (Minecraft-style: WASD relative
## to the camera's heading, quick to start and stop on the ground, little
## control in the air). Into water: Swim. E on rock too steep to walk: Climb.

const RUN_FACTOR := 1.3        ## Ctrl.
const SETTLE := 1.0            ## s of slower walking after pulling up over an edge.

var settle := 0.0              ## Time left walking slowly (after a mantle).


func enter(_from: StringName, args: Dictionary) -> void:
	settle = args.get("settle", 0.0)
	player.reset_collision()
	player.water_height = -INF
	player.set_head_under(false)


func physics(delta: float) -> void:
	var p := player
	var pos := p.global_position
	var body := Water.body_at(pos.x, pos.z)
	if body:
		p.change_mode(&"SWIM")
		p.mode.physics(delta)
		return
	p.set_water(null)
	p.velocity.y -= Player.LAND_GRAVITY * delta * (Player.FALL_GRAVITY if p.velocity.y < 0.0 else 1.0)
	settle = maxf(settle - delta, 0.0)
	walk(p, delta, p.is_on_floor(), settle / SETTLE)
	p.move_and_slide()
	# never under the ground (if something ever pushes the body through the
	# collider, it's put back on top rather than falling into the void)
	var g := Terrain.height_at(p.global_position.x, p.global_position.z)
	if g > Terrain.NO_GROUND and p.global_position.y - Player.CHEST < g - 0.6:
		p.global_position.y = g + Player.CHEST
		p.velocity.y = maxf(p.velocity.y, 0.0)
	pose = &"WALKING" if p.is_on_floor() else &"AIRBORNE"


func input(event: InputEvent) -> bool:
	if event.is_action_pressed(&"climb"):
		return player.try_climb()
	return false


## Walking (on land, or wading): toward the intent at walking speed, Ctrl
## faster, Shift sneaking, slower still just after a mantle (slow_down 0..1);
## holding Space jumps whenever the feet touch down. Shared with SwimMode.
static func walk(p: Player, delta: float, grounded: bool, slow_down := 0.0) -> void:
	var it := p.intent
	var wish := p.camera_relative(it.move)
	var speed := p.walk_speed
	if it.sprint and it.move.y > 0.0:
		speed *= RUN_FACTOR
	if it.sneak:
		speed *= 0.3
	speed *= lerpf(1.0, 0.3, slow_down)
	var target := wish * speed
	var vh := Vector2(p.velocity.x, p.velocity.z)
	var rate := 18.0 if grounded else (2.0 if wish != Vector2.ZERO else 0.1)
	vh = vh.lerp(target, 1.0 - exp(-rate * delta))
	# the faster you run, the harder you keep to the ground (running over a
	# crest or down a slope doesn't throw you into the air)
	p.floor_snap_length = 1.2 + 0.08 * vh.length()
	if grounded and it.jump:
		p.velocity.y = p.jump_speed
		vh = vh.limit_length(Player.JUMP_CARRY)   # (a running jump carries you no further than a brisk one)
	p.velocity.x = vh.x
	p.velocity.z = vh.y
