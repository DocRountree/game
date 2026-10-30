class_name MantleMode
extends PlayerMode
## Pulling up over the top of a climb: up first, then over onto the ground,
## the body passing over the edge (no collision), in MANTLE_TIME. Then Walk,
## slowly for a moment (no stepping straight off the edge).

const TIME := 0.45             ## s

var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _normal := Vector3.BACK
var _t := 0.0


func enter(_from_mode: StringName, args: Dictionary) -> void:
	_from = player.global_position
	_to = args.get("to", _from)
	_normal = args.get("normal", Vector3.BACK)
	_t = 0.0
	player.set_collision_enabled(false)
	pose = &"CLIMBING"


func exit() -> void:
	player.set_collision_enabled(true)
	player.reset_collision()


func physics(delta: float) -> void:
	var p := player
	_t = minf(_t + delta / TIME, 1.0)
	var pos := _from.lerp(_to, _t * _t)
	pos.y = lerpf(_from.y, _to.y, 1.0 - (1.0 - _t) * (1.0 - _t)) + sin(PI * _t) * 0.25
	p.global_position = pos
	p.velocity = Vector3.ZERO
	if _t >= 1.0:
		p.change_mode(&"WALK", {"settle": WalkMode.SETTLE})
		var on := Vector3(-_normal.x, 0.0, -_normal.z)
		p.velocity = on.normalized() * 1.0 if on.length() > 0.01 else Vector3.ZERO


func orient(_delta: float) -> void:
	player.face_rock(_normal)
