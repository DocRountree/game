class_name PlayerCamera
extends Camera3D
## The player's camera. Third person: orbits the target, mouse (when captured)
## or arrow keys to look, optionally swinging back behind a vehicle's heading
## when left alone. First person: sits at the eyes node and looks where the
## same yaw and pitch point.

@export var target: Node3D
@export var distance := 4.5
@export var target_offset := Vector3(0, 0.5, 0)
@export var follow_heading := false   ## Swing behind the target when idle (vehicles).
@export var mouse_sensitivity := 0.0035
@export var min_pitch := -0.25        ## Third person: how far below the target the camera may go.
@export var max_pitch := 1.3
@export var first_person := false:
	set(value):
		first_person = value
		pitch = clampf(pitch, _pitch_limits().x, _pitch_limits().y)
@export var eyes: Node3D              ## Where the camera sits in first person.

var yaw := 0.0
var pitch := 0.25                     ## Third person: camera elevation. First person: looking down (+) or up (-).

var _distance := 4.5
var _idle := 10.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		var limits := _pitch_limits()
		pitch = clampf(pitch + event.relative.y * mouse_sensitivity, limits.x, limits.y)
		_idle = 0.0


func _process(delta: float) -> void:
	if target == null:
		return
	_idle += delta
	var orbit := Input.get_axis(&"camera_left", &"camera_right")
	if orbit != 0.0:
		yaw -= orbit * 1.8 * delta
		_idle = 0.0
	var limits := _pitch_limits()
	pitch = clampf(pitch + Input.get_axis(&"camera_up", &"camera_down") * 1.2 * delta, limits.x, limits.y)

	if follow_heading and _idle > 1.5:
		var fwd := -target.global_basis.z
		var behind := atan2(-fwd.x, -fwd.z)
		yaw += angle_difference(yaw, behind) * minf(1.0, 1.5 * delta)

	if first_person and eyes:
		global_position = eyes.global_position + Vector3(0, 0.06, 0)
		look_at(global_position + Vector3(-sin(yaw) * cos(pitch), -sin(pitch), -cos(yaw) * cos(pitch)))
		return

	_distance = lerpf(_distance, distance, minf(1.0, 3.0 * delta))
	var focus := target.global_position + target_offset
	var eye := focus + _distance * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	if Ocean.instance:
		eye.y = maxf(eye.y, Ocean.instance.height_at(eye.x, eye.z, 0.0, 0.0) + 0.4)   # stay above water
	global_position = global_position.lerp(eye, minf(1.0, 12.0 * delta))
	look_at(focus)


func _pitch_limits() -> Vector2:
	return Vector2(-1.45, 1.45) if first_person else Vector2(min_pitch, max_pitch)
