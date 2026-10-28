class_name CharacterRig
extends Node3D
## The player's body: a stylized explorer built from simple shapes (rounded
## head with hair, ears and a nose, a wide-brimmed hat, a tapered shirt with a
## belt, a knapsack with a bedroll, sleeved arms with hands, trousers and
## boots), animated entirely procedurally, with no animation clips:
##   - walking: each foot is planted on the ground and steps in an arc when the
##     body has moved on, feet alternating; faster than feet can be planted
##     it becomes a running cycle around the hips, still set on the ground
##     below; the arms swing against the legs;
##   - in the air the legs hang and the arms lift a little; in debug flight
##     the arms sweep back;
##   - swimming: a front crawl (each arm circling from reaching overhead down
##     under the body and back over the water) with a flutter kick; treading:
##     sculling hands and cycling legs; sinking: limbs drifting up;
##   - aboard the boat: hands forward on the helm;
##   - climbing: hands and feet hold points on the rock and move in a
##     diagonal gait (left hand with right foot, then the other pair), each
##     lifting off the rock and reaching to a new hold when the body has
##     moved on.
## Arms and legs are two-bone chains solved toward their targets each frame,
## elbows and knees bending the way the pose needs.

const THIGH := 0.43
const SHIN := 0.43
const UPPER_ARM := 0.28
const FOREARM := 0.27
const HIP := Vector3(0.095, -0.45, 0.0)        ## Model space (the player's origin is the chest).
const SHOULDER := Vector3(0.205, 0.13, 0.0)
const FOOT_DROP := 0.04                         ## Ankle above the sole.
const RUN_SPEED := 4.5                          ## m/s: above it the feet run a cycle instead of planting.

var player: Player

var _limb: Dictionary = {}          # name -> MeshInstance3D (top-level, posed in world space)
var _feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _to: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _t := PackedFloat32Array([-1.0, -1.0])     # step progress 0..1, -1 = planted
var _last := 1
var _walk_ready := false
var _phase := 0.0
# climbing: hands 0, 1 (left, right) and feet 2, 3, each held on the rock
var _holds: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hold_from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hold_to: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hold_t := PackedFloat32Array([-1.0, -1.0, -1.0, -1.0])
var _climb_ready := false
var _climb_pair := 0
var _time := 0.0


## Build the body under the player's model node (named parts carry a "tint"
## meta that CharacterTraits.apply_to() recolours).
func build() -> void:
	var m := player.model
	var skin := _mat(Color(0.85, 0.6, 0.45))
	var shirt := _mat(Color(0.75, 0.12, 0.08))
	var trousers := _mat(Color(0.08, 0.15, 0.35))
	var hair := _mat(Color(0.2, 0.13, 0.08))
	var leather := _mat(Color(0.32, 0.2, 0.11))
	var canvas := _mat(Color(0.62, 0.53, 0.36))
	var dark := _mat(Color(0.07, 0.06, 0.05))
	var roll := _mat(Color(0.33, 0.38, 0.3))
	# torso
	_part(m, "Torso", _cyl(0.19, 0.155, 0.44), shirt, Vector3(0, -0.1, 0), Vector3(1, 1, 0.68), "shirt")
	for x: float in [-1.0, 1.0]:
		_part(m, "Shoulder", _sphere(0.075), shirt, Vector3(0.2 * x, 0.11, 0), Vector3(1, 0.9, 0.9), "shirt")
	_part(m, "Belt", _cyl(0.159, 0.159, 0.05), leather, Vector3(0, -0.33, 0), Vector3(1, 1, 0.7))
	_part(m, "Buckle", _box(Vector3(0.05, 0.035, 0.01)), canvas, Vector3(0, -0.33, -0.112), Vector3.ONE)
	_part(m, "Shorts", _cyl(0.158, 0.17, 0.17), trousers, Vector3(0, -0.43, 0), Vector3(1, 1, 0.74), "shorts")
	# head
	_part(m, "Neck", _cyl(0.05, 0.055, 0.1), skin, Vector3(0, 0.2, 0), Vector3.ONE, "skin")
	var head := _part(m, "Head", _sphere(0.12), skin, Vector3(0, 0.31, -0.005), Vector3(0.95, 1.08, 1.0), "skin")
	_part(head, "Hair", _sphere(0.126), hair, Vector3(0, 0.022, 0.016), Vector3(1.02, 0.82, 1.05), "hair")
	for x: float in [-1.0, 1.0]:
		_part(head, "Eye", _sphere(0.017), dark, Vector3(0.043 * x, 0.012, -0.108), Vector3.ONE)
		_part(head, "Ear", _sphere(0.026), skin, Vector3(0.118 * x, -0.005, 0.0), Vector3(0.5, 1.0, 0.8), "skin")
	_part(head, "Nose", _sphere(0.022), skin, Vector3(0, -0.012, -0.118), Vector3(0.8, 1.0, 1.1), "skin")
	_part(head, "HatBrim", _cyl(0.21, 0.21, 0.014), canvas, Vector3(0, 0.072, 0), Vector3(1, 1, 1.05))
	_part(head, "HatCrown", _cyl(0.1, 0.122, 0.1), canvas, Vector3(0, 0.125, 0), Vector3(1, 1, 1.05))
	_part(head, "HatBand", _cyl(0.123, 0.123, 0.022), leather, Vector3(0, 0.088, 0), Vector3(1, 1, 1.05))
	# the knapsack, with a bedroll on top
	_part(m, "Pack", _box(Vector3(0.28, 0.34, 0.13)), leather, Vector3(0, -0.07, 0.165), Vector3.ONE)
	var bed := _part(m, "Bedroll", _cyl(0.055, 0.055, 0.34), roll, Vector3(0, 0.14, 0.17), Vector3.ONE)
	bed.rotation = Vector3(0, 0, PI * 0.5)
	# limbs: placed in world space every frame
	for side: String in ["L", "R"]:
		_limb["upper" + side] = _limb_part(m, _capsule(0.056, UPPER_ARM + 0.08), shirt, "shirt")
		_limb["fore" + side] = _limb_part(m, _capsule(0.046, FOREARM + 0.06), skin, "skin")
		_limb["hand" + side] = _limb_part(m, _sphere(0.05), skin, "skin")
		_limb["thigh" + side] = _limb_part(m, _capsule(0.08, THIGH + 0.08), trousers, "shorts")
		_limb["shin" + side] = _limb_part(m, _capsule(0.066, SHIN + 0.04), trousers, "shorts")
		_limb["boot" + side] = _limb_part(m, _box(Vector3(0.11, 0.09, 0.25)), leather)


func _process(delta: float) -> void:
	_time += delta
	if not player.model.visible:
		_walk_ready = false
		_climb_ready = false
		return
	var b := player.model.global_transform
	var s := b.basis.get_scale().y
	var hips: Array[Vector3] = [b * Vector3(-HIP.x, HIP.y, 0), b * Vector3(HIP.x, HIP.y, 0)]
	var shoulders: Array[Vector3] = [b * Vector3(-SHOULDER.x, SHOULDER.y, 0), b * Vector3(SHOULDER.x, SHOULDER.y, 0)]
	var fwd := -b.basis.z.normalized()
	var right := b.basis.x.normalized()
	var up := b.basis.y.normalized()
	var feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var hands: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var knee_pole: Array[Vector3] = [fwd, fwd]
	var elbow_pole: Array[Vector3] = [-fwd - right * 0.3, -fwd + right * 0.3]
	var st := player.state
	if st != &"CLIMBING":
		_climb_ready = false
	if st == &"CLIMBING":
		_climb(delta, s, hips, shoulders, feet, hands)
		var n := player.climb_normal
		var side := right
		knee_pole = [-side * 0.8 - n * 0.3, side * 0.8 - n * 0.3]
		elbow_pole = [-side * 0.8 - up * 0.5 + n * 0.2, side * 0.8 - up * 0.5 + n * 0.2]
	elif st == &"WALKING" or st == &"AIRBORNE" or st == &"FLYING":
		_walk(delta, s, hips, feet)
		# arms swing against the legs (forward with the opposite foot)
		var swing := clampf((feet[1] - feet[0]).dot(fwd) / (0.6 * s), -1.0, 1.0)
		for i in 2:
			var sx := -1.0 if i == 0 else 1.0
			var a := swing * (1.0 if i == 0 else -1.0)
			var local := Vector3(sx * 0.07, -0.5, -0.2 * a)
			if st == &"AIRBORNE":
				local = Vector3(sx * 0.2, -0.38, -0.12)
			elif st == &"FLYING":
				local = Vector3(sx * 0.12, -0.42, 0.3)
			hands[i] = shoulders[i] + b.basis * local
		_walk_ready = true
	else:
		_walk_ready = false
		var t := _time
		for i in 2:
			var sx := -1.0 if i == 0 else 1.0
			var ph := PI * i
			var hand_l := Vector3.ZERO
			var foot_l := Vector3(sx * HIP.x, -0.45 - 0.82, 0.0)
			match st:
				&"SWIMMING", &"DIVING":
					# front crawl: reach overhead, pull down under the body, recover over the water
					var th := t * (5.5 if Input.is_action_pressed(&"sprint") else 4.0) + ph
					hand_l = Vector3(sx * 0.06, cos(th) * 0.5, -sin(th) * 0.45)
					if sin(th) < 0.0:
						hand_l.z *= 0.6   # (the recovery stays close over the back)
					foot_l += Vector3(0, 0, sin(t * 9.0 + ph) * 0.13)
					elbow_pole[i] = right * sx + up * 0.2 + b.basis.z * 0.6
				&"TREADING":
					hand_l = Vector3(sx * (0.2 + 0.1 * sin(t * 4.0)), -0.28, -0.3)
					foot_l += Vector3(0, 0.12 + 0.08 * sin(t * 5.0 + ph), -0.12 * cos(t * 5.0 + ph))
				&"ON BOAT":
					hand_l = Vector3(sx * 0.17, -0.06, -0.4)
					foot_l = Vector3(sx * 0.13, -0.45 - 0.84, -0.02)
				_:   # sinking, or anything else: drifting
					hand_l = Vector3(sx * (0.3 + 0.04 * sin(t * 1.3 + ph)), 0.0, -0.08)
					foot_l += Vector3(sx * 0.05, 0.1, 0.05 * sin(t * 1.1 + ph))
			hands[i] = shoulders[i] + b.basis * hand_l
			feet[i] = b * foot_l
	for i in 2:
		var side := "L" if i == 0 else "R"
		var knee := _ik(hips[i], feet[i], THIGH * s, SHIN * s, knee_pole[i])
		_place(_limb["thigh" + side], hips[i], knee, s)
		_place(_limb["shin" + side], knee, feet[i], s)
		var elbow := _ik(shoulders[i], hands[i], UPPER_ARM * s, FOREARM * s, elbow_pole[i])
		_place(_limb["upper" + side], shoulders[i], elbow, s)
		_place(_limb["fore" + side], elbow, hands[i], s)
		var fore_dir := (hands[i] - elbow).normalized()
		var hand: MeshInstance3D = _limb["hand" + side]
		hand.global_transform = Transform3D(_basis_along(fore_dir).scaled(Vector3(0.8, 1.15, 0.6) * s), hands[i] + fore_dir * 0.035 * s)
		# the boot: flat under the ankle, pointing where the body faces (on a
		# wall, its sole against the rock)
		var boot: MeshInstance3D = _limb["boot" + side]
		var toe := fwd
		var sole := up
		if st == &"CLIMBING":
			sole = (up * 0.6 + player.climb_normal * 0.4).normalized()
			toe = -player.climb_normal
		toe = (toe - sole * toe.dot(sole)).normalized()
		var bx := sole.cross(toe).normalized()
		boot.global_transform = Transform3D(Basis(bx, sole, -toe).scaled(Vector3.ONE * s),
				feet[i] - sole * FOOT_DROP * 0.3 * s + toe * 0.06 * s)


# --- walking ----------------------------------------------------------------------

func _walk(delta: float, s: float, hips: Array[Vector3], feet: Array[Vector3]) -> void:
	var leg := (THIGH + SHIN) * s
	if not _walk_ready:
		for i in 2:
			_feet[i] = _ground_below(hips[i], leg)
			_t[i] = -1.0
	var vel := Vector3(player.velocity.x, 0.0, player.velocity.z)
	var speed := vel.length()
	var airborne := player.state != &"WALKING"
	# strides lengthen up to what the legs can reach, then steps just quicken
	var reach := minf(0.22 + speed * 0.11, 0.85) * s
	var step_time := clampf(reach / maxf(speed, 0.01) * 0.9, 0.06, 0.32)
	if not airborne and speed > RUN_SPEED:
		# too fast to plant each foot: a running cycle, each foot swinging
		# forward lifted and pushing back along the ground below the hip
		_phase = fmod(_phase + delta * clampf(speed / 1.8, 2.2, 4.0), 1.0)
		var dir := vel / speed
		var stride := minf(0.3 + speed * 0.025, 0.7) * s
		for i in 2:
			var ph := TAU * (_phase + 0.5 * i)
			_feet[i] = _ground_below(hips[i], leg) + dir * sin(ph) * stride \
					+ Vector3.UP * maxf(0.0, cos(ph)) * 0.25 * s
			_t[i] = -1.0
			feet[i] = _feet[i] + Vector3.UP * FOOT_DROP * s
		return
	for i in 2:
		if airborne:
			_feet[i] = _feet[i].lerp(hips[i] + Vector3.DOWN * (leg - 0.1 * s) + vel * 0.05, minf(1.0, 10.0 * delta))
			_t[i] = -1.0
			continue
		if _t[i] >= 0.0:
			_t[i] = minf(_t[i] + delta / step_time, 1.0)
			var e := _t[i] * _t[i] * (3.0 - 2.0 * _t[i])
			_feet[i] = _from[i].lerp(_to[i], e) + Vector3.UP * sin(PI * _t[i]) * (0.06 + speed * 0.02) * s
			if _t[i] >= 1.0:
				_feet[i] = _to[i]
				_t[i] = -1.0
	if not airborne and _t[0] < 0.0 and _t[1] < 0.0:
		# step with the leg that has fallen furthest behind (alternating on ties)
		var best := -1
		var best_d := 0.0
		for i in 2:
			var ideal := _ground_below(hips[i] + vel * step_time * 0.9, leg)
			var d := Vector2(_feet[i].x - ideal.x, _feet[i].z - ideal.z).length()
			var need := reach if speed > 0.2 else 0.12 * s
			if d > need and (d > best_d or (is_equal_approx(d, best_d) and i != _last)):
				best = i
				best_d = d
		if best >= 0:
			_from[best] = _feet[best]
			_to[best] = _ground_below(hips[best] + vel * step_time * 1.2, leg)
			_t[best] = 0.0
			_last = best
	for i in 2:
		feet[i] = _feet[i] + Vector3.UP * FOOT_DROP * s


func _ground_below(p: Vector3, leg: float) -> Vector3:
	var hit := _ray(p + Vector3.UP * 0.4, p + Vector3.DOWN * 2.5)
	if hit:
		return hit.position
	return p + Vector3.DOWN * leg   # nothing underfoot: the leg hangs


# --- climbing ------------------------------------------------------------------------

# The four holds: each limb has an ideal hold relative to the body on the
# rock; when its hold falls too far behind, it reaches for a new one, two
# diagonal limbs at a time.
func _climb(delta: float, s: float, hips: Array[Vector3], shoulders: Array[Vector3],
		feet: Array[Vector3], hands: Array[Vector3]) -> void:
	var n := player.climb_normal
	var up := (Vector3.UP - n * Vector3.UP.dot(n)).normalized()
	var right := up.cross(n).normalized()
	var ideal: Array[Vector3] = [
		shoulders[0] + up * 0.36 * s - right * 0.1 * s,
		shoulders[1] + up * 0.36 * s + right * 0.1 * s,
		hips[0] - up * 0.62 * s - right * 0.08 * s,
		hips[1] - up * 0.62 * s + right * 0.08 * s,
	]
	# lead with the limbs in the direction of travel
	var v := player.velocity
	for k in 4:
		ideal[k] += v * 0.18
	if not _climb_ready:
		for k in 4:
			_holds[k] = _on_rock(ideal[k], n)
			_hold_t[k] = -1.0
		_climb_ready = true
	var stepping := false
	for k in 4:
		if _hold_t[k] >= 0.0:
			stepping = true
			_hold_t[k] = minf(_hold_t[k] + delta / 0.22, 1.0)
			var e := _hold_t[k] * _hold_t[k] * (3.0 - 2.0 * _hold_t[k])
			_holds[k] = _hold_from[k].lerp(_hold_to[k], e) + n * sin(PI * _hold_t[k]) * 0.12 * s
			if _hold_t[k] >= 1.0:
				_holds[k] = _hold_to[k]
				_hold_t[k] = -1.0
	if not stepping:
		# the diagonal pair that has fallen further behind reaches on
		var pairs := [[0, 3], [1, 2]]
		var lag := [0.0, 0.0]
		for p in 2:
			for k: int in pairs[p]:
				var d := _holds[k] - ideal[k]
				lag[p] = maxf(lag[p], (d - n * d.dot(n)).length())
		var p := 0 if lag[0] > lag[1] or (is_equal_approx(lag[0], lag[1]) and _climb_pair == 1) else 1
		if lag[p] > 0.3 * s:
			for k: int in pairs[p]:
				_hold_from[k] = _holds[k]
				_hold_to[k] = _on_rock(ideal[k] + v * 0.15, n)
				_hold_t[k] = 0.0
			_climb_pair = p
	hands[0] = _holds[0] + n * 0.03 * s
	hands[1] = _holds[1] + n * 0.03 * s
	feet[0] = _holds[2] + n * 0.06 * s
	feet[1] = _holds[3] + n * 0.06 * s


func _on_rock(p: Vector3, n: Vector3) -> Vector3:
	var hit := _ray(p + n * 0.7, p - n * 0.9)
	return hit.position if hit else p - n * 0.05


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = [player.get_rid()]
	return player.get_world_3d().direct_space_state.intersect_ray(q)


# --- solving and placing ---------------------------------------------------------------

## Two-bone chain from root toward target: where the middle joint goes,
## bending toward pole. (The target is pulled in if out of reach.)
static func _ik(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var to := target - root
	var dist := clampf(to.length(), 0.05, l1 + l2 - 0.001)
	var dir := to.normalized() if to.length() > 0.001 else Vector3.DOWN
	var a := (l1 * l1 + dist * dist - l2 * l2) / (2.0 * l1 * dist)
	var bend := pole - dir * pole.dot(dir)
	if bend.length() < 1e-4:
		bend = dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD)
	return root + dir * l1 * a + bend.normalized() * l1 * sqrt(maxf(0.0, 1.0 - a * a))


static func _basis_along(y: Vector3) -> Basis:
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	return Basis(x, y, x.cross(y))


static func _place(m: MeshInstance3D, a: Vector3, b: Vector3, s: float) -> void:
	var y := (b - a).normalized() if a.distance_to(b) > 1e-4 else Vector3.DOWN
	m.global_transform = Transform3D(_basis_along(y).scaled(Vector3.ONE * s), (a + b) * 0.5)


# --- building ------------------------------------------------------------------------------

static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m


static func _part(parent: Node3D, part_name: String, mesh: Mesh, mat: Material, pos: Vector3, scale_: Vector3, tint := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scale_
	if tint != "":
		mi.set_meta(&"tint", tint)
	parent.add_child(mi, true)
	return mi


static func _limb_part(parent: Node3D, mesh: Mesh, mat: Material, tint := "") -> MeshInstance3D:
	var mi := _part(parent, "Limb", mesh, mat, Vector3.ZERO, Vector3.ONE, tint)
	mi.top_level = true
	return mi


static func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = 16
	c.rings = 1
	return c


static func _sphere(r: float) -> SphereMesh:
	var sp := SphereMesh.new()
	sp.radius = r
	sp.height = r * 2.0
	sp.radial_segments = 16
	sp.rings = 8
	return sp


static func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 12
	c.rings = 4
	return c


static func _box(size: Vector3) -> BoxMesh:
	var bx := BoxMesh.new()
	bx.size = size
	return bx
