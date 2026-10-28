class_name Boat
extends RigidBody3D
## A boat. Buoyancy (a child component) keeps it afloat; this adds thrust, keel
## drag (slides forward easily, sideways hardly at all), a rudder that bites
## harder with speed, bow lift and a lean into turns. How hard each of those
## pulls comes from its BoatSpec, so boats differ by data, not code.
##
## BoatStation children mark where the player steers, fishes or works; the
## Cargo child is the hold, sized from the spec.

@export var spec: BoatSpec

var throttle := 0.0   ## -1..1, set by whoever is driving.
var steer := 0.0      ## -1..1, positive turns left.
var driver: Node3D

@export_group("Trackers")
@export var odometer_m := 0.0       ## Distance travelled under way.
@export var hours_underway := 0.0   ## Real hours with a driver aboard.
@export var top_speed := 0.0        ## m/s

@onready var buoyancy: Buoyancy = $Buoyancy
@onready var cargo: Inventory = $Cargo
@onready var helm: BoatStation = station(BoatStation.Kind.HELM)
var _yaw_inertia := 0.0


func _ready() -> void:
	if spec == null:
		spec = BoatSpec.new()
	mass = spec.mass
	cargo.capacity = spec.cargo_slots
	_yaw_inertia = mass * (spec.length * spec.length + spec.beam * spec.beam) / 12.0


func _physics_process(delta: float) -> void:
	var v := speed()
	if driver:
		odometer_m += v * delta
		hours_underway += delta / 3600.0
		top_speed = maxf(top_speed, v)
	_stay_upright()
	if buoyancy.submerged <= 0.0:
		return
	var fwd := -global_basis.z
	var right := global_basis.x
	var current := buoyancy.water.flow_at(global_position.x, global_position.z) if buoyancy.water else Vector3.ZERO
	var v_water := linear_velocity - current   # drag acts against the water, so rivers carry the boat
	var v_fwd := v_water.dot(fwd)
	var v_side := v_water.dot(right)
	var v_ctl := clampf(v_fwd, -15.0, 15.0)   # rudder, lift and lean stop growing past ~15 m/s
	var thrust := throttle * (spec.thrust_forward if throttle > 0.0 else spec.thrust_reverse)
	apply_central_force(fwd * (thrust - spec.drag_forward_quadratic * v_fwd * absf(v_fwd) - spec.drag_forward_linear * v_fwd)
			+ right * (-spec.drag_side_quadratic * v_side * absf(v_side) - spec.drag_side_linear * v_side))
	var yaw_rate := angular_velocity.y
	apply_torque(Vector3.UP * (steer * spec.steer_rate * v_ctl - spec.yaw_damping * yaw_rate) * _yaw_inertia)
	apply_torque(right * spec.bow_lift * maxf(v_ctl, 0.0))     # bow lifts at speed
	apply_torque(fwd * -spec.turn_lean * yaw_rate * v_ctl)     # lean into turns


# A keel's worth of stability: torque back toward level, plus damping of roll
# and pitch rates, applied even in the air so the boat lands flat after a jump.
func _stay_upright() -> void:
	var up := global_basis.y
	var tilt := up.cross(Vector3.UP)   # axis and sine of the tilt
	var spin := angular_velocity - Vector3.UP * angular_velocity.dot(Vector3.UP)   # roll and pitch only
	var inertia := mass * (spec.length * spec.length) / 12.0
	apply_torque((tilt * spec.righting - spin * spec.righting_damping) * inertia)


func speed() -> float:
	return linear_velocity.length()


## The first station of a kind (null if this boat has none, e.g. no research bench).
func station(kind: BoatStation.Kind) -> BoatStation:
	for child in get_children():
		if child is BoatStation and child.kind == kind:
			return child
	return null


func stations() -> Array[BoatStation]:
	var out: Array[BoatStation] = []
	for child in get_children():
		if child is BoatStation:
			out.append(child)
	return out
