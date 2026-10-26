class_name Buoyancy
extends Node3D
## Spring buoyancy for the parent RigidBody3D. Every Marker3D child is a probe.
##
## Each probe pushes up with rho * g * (area / probes) * depth: one-sided (no
## pull when out of the water) and capped at max_depth (fully submerged). Drag
## against the water's own vertical motion damps the bobbing. Probes at the hull
## corners give pitch and roll for free.
##
## Works on any WaterBody (each probe asks Water which body it is in), and
## floats lower in fresh water than in the sea.
##
## It can also make ripples: the hull's submerged depth is reported to the ocean
## as a displacement source, so moving it makes a wake.

@export var waterplane_area := 1.0   ## Hull area at the waterline (m^2).
@export var max_depth := 1.0         ## Hull depth: buoyancy stops growing past this.
@export var footprint := 0.0         ## Ignore swell shorter than this (m). ~hull width.
@export var drag_linear := 880.0     ## Vertical drag per m^2 of probe area.
@export var drag_quadratic := 330.0

@export_group("Ripples")
## Feel the interactive ripples (wakes). Off for big hulls that make them: their
## own displacement trough would otherwise pull them down.
@export var feels_ripples := true
@export var ripple_sample_radius := 0.8  ## Read ripples just outside the hull, not its own trough.
@export var ripple_push := 1.2           ## How hard ripple slopes shove it sideways.
@export_enum("None", "Hull", "Box", "Disc") var ripple_shape := 0
@export var ripple_half_extents := Vector2(0.5, 0.5)  ## Half length (forward), half width (m).
@export var ripple_gain := 1.0           ## Scales the displaced depth (wake strength).

var submerged := 0.0   ## 0..1, averaged over probes.
var water: WaterBody   ## The body under the hull's centre (null on land).

var _body: RigidBody3D
var _probes: Array[Marker3D] = []
var _prev_h := PackedFloat32Array()
var _swell_depth := 0.0   # average depth against the swell alone (ripple source)


func _ready() -> void:
	_body = get_parent() as RigidBody3D
	for child in get_children():
		if child is Marker3D:
			_probes.append(child)
	_prev_h.resize(_probes.size())
	_prev_h.fill(NAN)
	if ripple_shape != 0:
		add_to_group(&"ripple_sources")


func _physics_process(delta: float) -> void:
	if _body == null or _probes.is_empty():
		return
	water = Water.body_at(_body.global_position.x, _body.global_position.z)
	var n := _probes.size()
	var area := waterplane_area / n
	var total := 0.0
	var swell_total := 0.0
	var origin := _body.global_position
	for i in n:
		var p := _probes[i].global_position
		var body := Water.body_at(p.x, p.z)
		if body == null:
			_prev_h[i] = NAN
			continue
		var swell := body.surface_height(p.x, p.z, footprint)
		var h := swell
		if feels_ripples:
			h += body.ripple_height(p.x, p.z, ripple_sample_radius)
		var water_vy := 0.0 if is_nan(_prev_h[i]) else (h - _prev_h[i]) / delta
		_prev_h[i] = h
		var depth := clampf(h - p.y, 0.0, max_depth)
		swell_total += clampf(swell - p.y, 0.0, max_depth)
		total += depth
		if depth <= 0.0:
			continue
		var offset := p - origin
		var v := _body.linear_velocity + _body.angular_velocity.cross(offset)
		var vrel := v.y - water_vy
		var force := Vector3.UP * (body.density() * Water.G * area * depth
				- area * (drag_linear * vrel + drag_quadratic * vrel * absf(vrel)))
		if feels_ripples and ripple_push > 0.0:
			var s := body.ripple_slope(p.x, p.z)   # slide down ripple slopes
			force += Vector3(-s.x, 0.0, -s.y) * _body.mass * Water.G * ripple_push / n
		_body.apply_force(force, offset)
	submerged = total / (n * max_depth)
	_swell_depth = swell_total / n


## Displacement source for the ripple sim: 8 floats, see ripple_sim.glsl.
func ripple_source() -> PackedFloat32Array:
	if _body == null or _swell_depth <= 0.0:
		return PackedFloat32Array()
	var fwd := -_body.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var c := _body.global_position
	return PackedFloat32Array([c.x, c.z, fwd.x, fwd.z, ripple_half_extents.x, ripple_half_extents.y,
			_swell_depth * ripple_gain, float(ripple_shape - 1)])
