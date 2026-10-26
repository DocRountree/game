class_name ThirdPersonCamera
extends Camera3D
## Orbiting third-person camera. Mouse (when captured) or arrow keys orbit;
## optionally swings back behind the target's heading when left alone.

@export var target: Node3D
@export var distance := 4.5
@export var target_offset := Vector3(0, 0.5, 0)
@export var follow_heading := false   ## Swing behind the target when idle (vehicles).
@export var mouse_sensitivity := 0.0035
@export var min_pitch := -0.25
@export var max_pitch := 1.3

var yaw := 0.0
var pitch := 0.25

var _distance := 4.5
var _idle := 10.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch = clampf(pitch + event.relative.y * mouse_sensitivity, min_pitch, max_pitch)
		_idle = 0.0


func _process(delta: float) -> void:
	if target == null:
		return
	_idle += delta
	var orbit := Input.get_axis(&"camera_left", &"camera_right")
	if orbit != 0.0:
		yaw -= orbit * 1.8 * delta
		_idle = 0.0
	pitch = clampf(pitch + Input.get_axis(&"camera_up", &"camera_down") * 1.2 * delta, min_pitch, max_pitch)

	if follow_heading and _idle > 1.5:
		var fwd := -target.global_basis.z
		var behind := atan2(-fwd.x, -fwd.z)
		yaw += angle_difference(yaw, behind) * minf(1.0, 1.5 * delta)

	_distance = lerpf(_distance, distance, minf(1.0, 3.0 * delta))
	var focus := target.global_position + target_offset
	var eye := focus + _distance * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	if Ocean.instance:
		eye.y = maxf(eye.y, Ocean.instance.height_at(eye.x, eye.z, 0.0, 0.0) + 0.4)   # stay above water
	global_position = global_position.lerp(eye, minf(1.0, 12.0 * delta))
	look_at(focus)
