class_name ProceduralLegs
extends Node3D
## Walking legs with no animation clips: each foot is planted on the ground
## (a ray down onto the collider) and stays put until the body has moved far
## enough ahead, then steps in an arc to a new spot found the same way, a
## little ahead of the hip in the direction of travel. Feet alternate, steps
## quicken with speed, and a two-bone solver bends the knees forward so thigh
## and shin always reach the planted foot. In the air the legs hang; swimming
## and driving use the plain swimming legs.

const THIGH := 0.45
const SHIN := 0.45
const HIP_Y := -0.42      ## Hips below the player's origin (the chest).
const HIP_X := 0.1

var player: Player

var _feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _to: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _t := PackedFloat32Array([-1.0, -1.0])   # step progress 0..1, -1 = planted
var _last := 1             # the leg that stepped last
var _active := false
var _segments: Array[MeshInstance3D] = []   # thigh L, shin L, thigh R, shin R
var _plain_legs: Array[Node3D] = []


func _ready() -> void:
	var mat: Material = null
	for leg_name: String in ["LegL", "LegR"]:
		var leg := player.model.get_node_or_null(leg_name) as MeshInstance3D
		if leg:
			_plain_legs.append(leg)
			mat = (leg.mesh as PrimitiveMesh).material
	for i in 4:
		var m := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.085
		cap.height = (THIGH if i % 2 == 0 else SHIN) + 0.06
		cap.material = mat
		m.mesh = cap
		m.top_level = true
		m.visible = false
		add_child(m)
		_segments.append(m)


func _process(delta: float) -> void:
	var on_land := player.boat == null and player.model.visible \
			and (player.state == &"WALKING" or player.state == &"AIRBORNE" or player.state == &"FLYING")
	if on_land != _active:
		_active = on_land
		for leg in _plain_legs:
			leg.visible = not on_land
		for s in _segments:
			s.visible = on_land
		if on_land:
			for i in 2:
				_feet[i] = _ground_below(_hip(i))
				_t[i] = -1.0
	if not _active:
		return
	var vel := Vector3(player.velocity.x, 0.0, player.velocity.z)
	var speed := vel.length()
	var airborne := player.state != &"WALKING"
	# strides lengthen up to what the legs can reach, then steps just quicken
	var reach := minf(0.22 + speed * 0.11, 0.85)
	var step_time := clampf(reach / maxf(speed, 0.01) * 0.9, 0.06, 0.32)
	for i in 2:
		var hip := _hip(i)
		if airborne:
			# legs hang, a little apart
			_feet[i] = _feet[i].lerp(hip + Vector3.DOWN * (THIGH + SHIN - 0.08) + vel * 0.05, minf(1.0, 10.0 * delta))
			_t[i] = -1.0
			continue
		if _t[i] >= 0.0:
			_t[i] = minf(_t[i] + delta / step_time, 1.0)
			var e := _t[i] * _t[i] * (3.0 - 2.0 * _t[i])
			_feet[i] = _from[i].lerp(_to[i], e) + Vector3.UP * sin(PI * _t[i]) * (0.06 + speed * 0.02)
			if _t[i] >= 1.0:
				_feet[i] = _to[i]
				_t[i] = -1.0
	if not airborne and _t[0] < 0.0 and _t[1] < 0.0:
		# step with the leg that has fallen furthest behind (alternating on ties)
		var best := -1
		var best_d := 0.0
		for i in 2:
			var ideal := _ground_below(_hip(i) + vel * step_time * 0.9)
			var d := Vector2(_feet[i].x - ideal.x, _feet[i].z - ideal.z).length()
			var need := reach if speed > 0.2 else 0.12
			if d > need and (d > best_d or (is_equal_approx(d, best_d) and i != _last)):
				best = i
				best_d = d
		if best >= 0:
			_from[best] = _feet[best]
			_to[best] = _ground_below(_hip(best) + vel * step_time * 1.2)
			_t[best] = 0.0
			_last = best
	for i in 2:
		_pose_leg(i, _hip(i), _feet[i])


func _hip(i: int) -> Vector3:
	var b := Basis(Vector3.UP, player.model.rotation.y)
	return player.global_position + b * Vector3(HIP_X if i == 1 else -HIP_X, HIP_Y, 0.0)


func _ground_below(p: Vector3) -> Vector3:
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.4, p + Vector3.DOWN * 2.5)
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit:
		return hit.position
	return Vector3(p.x, Terrain.height_at(p.x, p.z), p.z)


# Two-bone IK: thigh and shin reach the foot, the knee bending forward.
func _pose_leg(i: int, hip: Vector3, foot: Vector3) -> void:
	var to_foot := foot - hip
	var dist := clampf(to_foot.length(), 0.05, THIGH + SHIN - 0.001)
	var dir := to_foot.normalized() if to_foot.length() > 0.001 else Vector3.DOWN
	foot = hip + dir * dist
	var a := (THIGH * THIGH + dist * dist - SHIN * SHIN) / (2.0 * THIGH * dist)
	var forward := Basis(Vector3.UP, player.model.rotation.y) * Vector3.FORWARD
	var bend := (forward - dir * forward.dot(dir)).normalized()
	var knee := hip + dir * THIGH * a + bend * THIGH * sqrt(maxf(0.0, 1.0 - a * a))
	_place(_segments[i * 2], hip, knee)
	_place(_segments[i * 2 + 1], knee, foot)


static func _place(m: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	m.global_transform = Transform3D(Basis(x, y, z), (a + b) * 0.5)
