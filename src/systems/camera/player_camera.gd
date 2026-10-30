class_name PlayerCamera
extends Camera3D
## The player's camera. Third person: orbits the target, mouse (when captured)
## or arrow keys to look; it comes in in front of whatever is between it and
## the target (a hill, a cliff), so you never see through the ground. First
## person: sits at the eyes node and looks where the same yaw and pitch point. The view stays where you leave it; on a
## vehicle it turns with the vehicle, so a look over the side stays a look
## over the side.
##
## It keeps its own rules, from what happens to `player` (Events): F5 toggles
## first and third person (in first person the player's own body is hidden,
## so you don't look out through your head); taking a boat's helm follows the
## boat from further back, turning with it; climbing is seen from behind
## (third person), and the view goes back to what it was once you're off the
## rock.

const FOLLOW_DISTANCE := 4.5
const FOLLOW_OFFSET := Vector3(0, 0.5, 0)
const BOAT_DISTANCE := 9.0
const BOAT_OFFSET := Vector3(0, 2.4, 0)

@export var player: Player          ## Who the camera follows (its eyes: Model/Head).
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
		if player and is_inside_tree():
			player.model.visible = not value   # (don't look out through your own head)
			var events := get_node_or_null(^"/root/Events")
			if events:
				events.view_mode_changed.emit(value)
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
var _view_before_climb := true
var _on_rock := false


func _ready() -> void:
	if player:
		target = player
		eyes = player.get_node_or_null(^"Model/Head")
	var events := get_node_or_null(^"/root/Events")
	if events:
		events.boat_boarded.connect(_on_boat_boarded)
		events.player_mode_changed.connect(_on_player_mode_changed)


func _on_boat_boarded(boat: Boat, boarded: bool) -> void:
	target = boat if boarded else player
	turn_with_target = boarded
	distance = BOAT_DISTANCE if boarded else FOLLOW_DISTANCE
	target_offset = BOAT_OFFSET if boarded else FOLLOW_OFFSET


func _on_player_mode_changed(mode: StringName) -> void:
	var on_rock := mode == &"CLIMB" or mode == &"MANTLE"
	if on_rock == _on_rock:
		return
	_on_rock = on_rock
	if on_rock:
		_view_before_climb = first_person
		first_person = false
	else:
		first_person = _view_before_climb


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_view") and not _on_rock:
		first_person = not first_person
		return
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
	# in front of anything in the way, and never under the ground
	var blocked := false
	var q := PhysicsRayQueryParameters3D.create(focus, eye, 1)
	if target is CollisionObject3D:
		q.exclude = [(target as CollisionObject3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		eye = (hit.position as Vector3) + (focus - eye).normalized() * 0.35
		blocked = true
	if Terrain.current():
		var ground := Terrain.height_at(eye.x, eye.z) + 0.4
		if eye.y < ground:
			eye.y = ground
			blocked = true
	# (straight there when something's in the way, so it never passes through it)
	global_position = eye if blocked else global_position.lerp(eye, minf(1.0, 12.0 * delta))
	look_at(focus)


func _pitch_limits() -> Vector2:
	return Vector2(-1.45, 1.45) if first_person else Vector2(min_pitch, max_pitch)
