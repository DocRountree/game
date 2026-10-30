class_name DriveMode
extends PlayerMode
## At a boat's helm: W/S throttle, A/D steer, the body riding the helm (no
## collision); Shift jumps off over the side (Walk, which hands over to Swim
## in the water).

var boat: Boat


func enter(_from: StringName, args: Dictionary) -> void:
	var p := player
	boat = args.boat
	p.boat = boat
	boat.driver = p
	boat.helm.occupant = p
	p.set_head_under(false)
	p.set_collision_enabled(false)
	p.velocity = Vector3.ZERO
	pose = &"ON BOAT"
	p.emit_event(&"boat_boarded", [boat, true])


func exit() -> void:
	var p := player
	var b := boat
	p.boat = null
	boat = null
	b.driver = null
	b.helm.occupant = null
	b.throttle = 0.0
	b.steer = 0.0
	p.set_collision_enabled(true)
	p.emit_event(&"boat_boarded", [b, false])


## Over the side: out to the boat's right, moving with it, with a hop.
func jump_off() -> void:
	var p := player
	var b := boat
	var side := b.global_basis.x
	p.change_mode(&"WALK")
	p.global_position = b.global_position + side * 2.1 + Vector3.UP * 1.2
	p.velocity = b.linear_velocity + side * 2.5 + Vector3.UP * 2.5


func physics(_delta: float) -> void:
	var p := player
	boat.throttle = p.intent.move.y
	boat.steer = -p.intent.move.x
	p.global_transform = boat.helm.global_transform
	p.velocity = boat.linear_velocity
	p.set_water(Water.body_at(p.global_position.x, p.global_position.z))
	p.water_height = Water.surface_height(p.global_position.x, p.global_position.z)


func input(event: InputEvent) -> bool:
	if event.is_action_pressed(&"dive"):
		jump_off()
		return true
	return false


## Aboard, only the body turns (to the camera), not the boat.
func orient(_delta: float) -> void:
	player.face_camera_aboard(boat)
