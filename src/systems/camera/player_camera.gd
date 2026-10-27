class_name PlayerCamera
extends Camera3D
## The player's camera. Third person: orbits the target, mouse (when captured)
## or arrow keys to look. First person: sits at the eyes node and looks where
## the same yaw and pitch point. The view stays where you leave it; on a
## vehicle it turns with the vehicle, so a look over the side stays a look
## over the side.

@export var target: Node3D
@export var distance := 4.5
@export var target_offset := Vector3(0, 0.5, 0)
@export var turn_with_target := false ## Carry the view round as the target turns (vehicles).
@export var mouse_sensitivity := 0.0035
@export var min_pitch := -0.25        ## Third person: how far below the target the camera may go.
@export var max_pitch := 1.3
@export var first_person := false:
	set(value):
		first_person = value
		pitch = clampf(pitch, _pitch_limits().x, _pitch_limits().y)
@export var eyes: Node3D              ## Where the camera sits in first person.
@export var base_fov := 65.0          ## Field of view at zoom 1.
## Magnification (spyglass, telescope): divides the field of view. The
## starfield's point size already follows the pixel angle, so stars stay sharp.
@export_range(1.0, 200.0) var zoom := 1.0:
	set(value):
		zoom = maxf(value, 1.0)
		fov = clampf(rad_to_deg(2.0 * atan(tan(deg_to_rad(base_fov) * 0.5) / zoom)), 0.05, 179.0)

var yaw := 0.0
var pitch := 0.25                     ## Third person: camera elevation. First person: looking down (+) or up (-).

var _distance := 4.5
var _last_heading := NAN


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := mouse_sensitivity / zoom   # finer aim when magnified
		yaw -= event.relative.x * sens
		var limits := _pitch_limits()
		pitch = clampf(pitch + event.relative.y * sens, limits.x, limits.y)


func _process(delta: float) -> void:
	if target == null:
		return
	yaw -= Input.get_axis(&"camera_left", &"camera_right") * 1.8 * delta
	var limits := _pitch_limits()
	pitch = clampf(pitch + Input.get_axis(&"camera_up", &"camera_down") * 1.2 * delta, limits.x, limits.y)

	var fwd := -target.global_basis.z
	var heading := atan2(-fwd.x, -fwd.z)
	if turn_with_target and not is_nan(_last_heading):
		yaw += angle_difference(_last_heading, heading)
	_last_heading = heading

	if first_person and eyes:
		global_position = eyes.global_position + Vector3(0, 0.06, 0)
		look_at(global_position + Vector3(-sin(yaw) * cos(pitch), -sin(pitch), -cos(yaw) * cos(pitch)))
		return

	_distance = lerpf(_distance, distance, minf(1.0, 3.0 * delta))
	var focus := target.global_position + target_offset
	var eye := focus + _distance * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	var surface := Water.surface_height(eye.x, eye.z, 0.0, 0.0)
	if target.global_position.y > surface - 1.0:
		eye.y = maxf(eye.y, surface + 0.4)   # stay above water, unless following a diver
	global_position = global_position.lerp(eye, minf(1.0, 12.0 * delta))
	look_at(focus)


func _pitch_limits() -> Vector2:
	return Vector2(-1.45, 1.45) if first_person else Vector2(min_pitch, max_pitch)
