class_name FlyMode
extends PlayerMode
## Debug flight (double-tap Space): no gravity, WASD relative to the camera,
## Space up, Shift down, Ctrl faster. Touching the ground on the way down
## lands you (Walk).

const SPEED := 120.0           ## m/s (Ctrl: 3 times).


func enter(_from: StringName, _args: Dictionary) -> void:
	player.reset_collision()
	player.water_height = -INF
	player.set_head_under(false)
	pose = &"FLYING"


func physics(delta: float) -> void:
	var p := player
	var it := p.intent
	var wish := p.camera_relative(it.move)
	var speed := SPEED * (3.0 if it.sprint else 1.0)
	var target := Vector3(wish.x, it.rise, wish.y) * speed
	p.velocity = p.velocity.lerp(target, 1.0 - exp(-6.0 * delta))
	p.move_and_slide()
	if p.is_on_floor() and it.rise < 0.0:
		p.change_mode(&"WALK")
		p.velocity = Vector3.ZERO
