class_name Boat
extends RigidBody3D
## Small motorboat. Buoyancy (a child component) keeps it afloat; this adds
## thrust, keel drag (slides forward easily, sideways hardly at all), a rudder
## that bites harder with speed, bow lift and a lean into turns.

@export var thrust_forward := 7000.0   ## N at full throttle.
@export var thrust_reverse := 3000.0
@export var steer_rate := 0.12         ## Yaw acceleration per m/s of forward speed.

var throttle := 0.0   ## -1..1, set by whoever is driving.
var steer := 0.0      ## -1..1, positive turns left.
var driver: Node3D

@onready var buoyancy: Buoyancy = $Buoyancy
@onready var seat: Marker3D = $Seat
@onready var _yaw_inertia := mass * (7.0 * 7.0 + 2.6 * 2.6) / 12.0


func _physics_process(_delta: float) -> void:
	if buoyancy.submerged <= 0.0:
		return
	var fwd := -global_basis.z
	var right := global_basis.x
	var v_fwd := linear_velocity.dot(fwd)
	var v_side := linear_velocity.dot(right)
	var thrust := throttle * (thrust_forward if throttle > 0.0 else thrust_reverse)
	apply_central_force(fwd * (thrust - 70.0 * v_fwd * absf(v_fwd) - 100.0 * v_fwd)
			+ right * (-1500.0 * v_side * absf(v_side) - 800.0 * v_side))
	var yaw_rate := angular_velocity.y
	apply_torque(Vector3.UP * (steer * steer_rate * v_fwd - 1.5 * yaw_rate) * _yaw_inertia)
	apply_torque(right * 6000.0 * maxf(v_fwd, 0.0))     # bow lifts at speed
	apply_torque(fwd * -2000.0 * yaw_rate * v_fwd)      # lean into turns


func speed() -> float:
	return linear_velocity.length()
