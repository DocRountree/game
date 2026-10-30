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
const HEAD := Vector3(0, 0.31, -0.005)         ## The head's centre in model space.
const RUN_SPEED := 4.5                          ## m/s: above it the feet run a cycle instead of planting.

var body: Character   ## The body it animates (the Player, later NPCs).

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
var material: ShaderMaterial        ## The one palette material (character.gdshader).
var _dress: MeshInstance3D
var _head_prev := Vector3.ZERO
var _sway := Vector3.ZERO
var _wet := 0.0


## Build the body under the player's model node: the static parts (torso,
## head, face, pack ...) as one mesh, the hair, beard, hat and accessories as
## another (CharacterDress, rebuilt by CharacterTraits.apply_to), the limbs
## one mesh each (posed every frame). All of them use the one palette
## material (character.gdshader), left on the model as meta for apply_to().
func build() -> void:
	var m := body.model
	material = ShaderMaterial.new()
	material.shader = preload("res://src/entities/player/character.gdshader")
	var default := CharacterTraits.new()
	material.set_shader_parameter("palette", default.palette())
	m.set_meta(&"character_material", material)
	var P := CharacterTraits
	var mb := MeshBuilder.new()
	# torso
	mb.add_mesh(_cyl(0.19, 0.155, 0.44), _xf(Vector3(0, -0.1, 0), Vector3(1, 1, 0.68)), P.P_SHIRT)
	for x: float in [-1.0, 1.0]:
		mb.add_mesh(_sphere(0.075), _xf(Vector3(0.2 * x, 0.11, 0), Vector3(1, 0.9, 0.9)), P.P_SHIRT)
	mb.add_mesh(_cyl(0.075, 0.085, 0.035), _xf(Vector3(0, 0.125, 0.0), Vector3(1, 1, 0.9)), P.P_SHIRT)   # collar
	mb.add_mesh(_cyl(0.159, 0.159, 0.05), _xf(Vector3(0, -0.33, 0), Vector3(1, 1, 0.7)), P.P_LEATHER)
	mb.add_mesh(_box(Vector3(0.05, 0.035, 0.01)), _xf(Vector3(0, -0.33, -0.112)), P.P_CANVAS)
	mb.add_mesh(_cyl(0.158, 0.17, 0.17), _xf(Vector3(0, -0.43, 0), Vector3(1, 1, 0.74)), P.P_SHORTS)
	# head: an ellipsoid, with ears, a nose, eyes and brows and a mouth
	var hs := Vector3(0.95, 1.08, 1.0)
	mb.add_mesh(_cyl(0.05, 0.055, 0.1), _xf(Vector3(0, 0.2, 0)), P.P_SKIN)
	mb.add_mesh(_sphere(0.12, 20, 10), _xf(HEAD, hs), P.P_SKIN)
	for x: float in [-1.0, 1.0]:
		mb.add_mesh(_sphere(0.017, 10, 6), _xf(HEAD + hs * Vector3(0.043 * x, 0.012, -0.108), hs), P.P_DARK)
		mb.add_mesh(_sphere(0.026, 10, 6), _xf(HEAD + hs * Vector3(0.118 * x, -0.005, 0.0), hs * Vector3(0.5, 1.0, 0.8)), P.P_SKIN)
		mb.add_mesh(_box(Vector3(0.034, 0.008, 0.006)), _xf(HEAD + Vector3(0.045 * x, 0.045, -0.1085), Vector3.ONE, Vector3(0.1, 0, -0.18 * x)), P.P_HAIR)
	mb.add_mesh(_sphere(0.022, 10, 6), _xf(HEAD + hs * Vector3(0, -0.012, -0.118), hs * Vector3(0.8, 1.0, 1.1)), P.P_SKIN)
	mb.add_mesh(_box(Vector3(0.04, 0.005, 0.006)), _xf(HEAD + Vector3(0, -0.05, -0.1075)), P.P_MOUTH)
	# the knapsack, with a bedroll on top
	mb.add_mesh(_box(Vector3(0.28, 0.34, 0.13)), _xf(Vector3(0, -0.07, 0.165)), P.P_LEATHER)
	mb.add_mesh(_cyl(0.055, 0.055, 0.34), _xf(Vector3(0, 0.14, 0.17), Vector3.ONE, Vector3(0, 0, PI * 0.5)), P.P_ROLL)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mb.commit()
	body.material_override = material
	m.add_child(body, true)
	# the head: where the camera sits in first person, and the hair etc. hang
	var head := Node3D.new()
	head.name = "Head"
	head.position = HEAD
	m.add_child(head, true)
	_dress = MeshInstance3D.new()
	_dress.name = "Dress"
	_dress.material_override = material
	head.add_child(_dress)
	m.set_meta(&"dress", _dress)
	# limbs: placed in world space every frame
	for side: String in ["L", "R"]:
		var arm := MeshBuilder.new()
		arm.add_mesh(_capsule(0.056, UPPER_ARM + 0.08), Transform3D.IDENTITY, P.P_SHIRT)
		arm.add_mesh(_cyl(0.062, 0.062, 0.035), _xf(Vector3(0, 0.1, 0)), P.P_SHIRT)   # a rolled sleeve
		_limb["upper" + side] = _limb_part(m, arm.commit())
		var fore := MeshBuilder.new()
		fore.add_mesh(_capsule(0.046, FOREARM + 0.06), Transform3D.IDENTITY, P.P_SKIN)
		_limb["fore" + side] = _limb_part(m, fore.commit())
		var hand := MeshBuilder.new()
		hand.add_mesh(_sphere(0.05, 10, 5), Transform3D.IDENTITY, P.P_SKIN)
		hand.add_mesh(_capsule(0.017, 0.07), _xf(Vector3(0, 0.0, 0.055), Vector3.ONE, Vector3(0.7, 0, 0)), P.P_SKIN)   # a thumb
		_limb["hand" + side] = _limb_part(m, hand.commit())
		var thigh := MeshBuilder.new()
		thigh.add_mesh(_capsule(0.08, THIGH + 0.08), Transform3D.IDENTITY, P.P_SHORTS)
		_limb["thigh" + side] = _limb_part(m, thigh.commit())
		var shin := MeshBuilder.new()
		shin.add_mesh(_capsule(0.066, SHIN + 0.04), Transform3D.IDENTITY, P.P_SHORTS)
		_limb["shin" + side] = _limb_part(m, shin.commit())
		var boot := MeshBuilder.new()
		boot.add_mesh(_box(Vector3(0.11, 0.09, 0.25)), Transform3D.IDENTITY, P.P_LEATHER)
		_limb["boot" + side] = _limb_part(m, boot.commit())
	_dress.mesh = CharacterDress.build(default)


## Dress the body in traits (scale, palette, hair ...).
func apply(traits: CharacterTraits) -> void:
	traits.apply_to(body.model)


func _process(delta: float) -> void:
	_time += delta
	if not body.model.visible:
		_walk_ready = false
		_climb_ready = false
		return
	var b := body.model.global_transform
	var s := b.basis.get_scale().y
	_hair_motion(b, delta)
	var hips: Array[Vector3] = [b * Vector3(-HIP.x, HIP.y, 0), b * Vector3(HIP.x, HIP.y, 0)]
	var shoulders: Array[Vector3] = [b * Vector3(-SHOULDER.x, SHOULDER.y, 0), b * Vector3(SHOULDER.x, SHOULDER.y, 0)]
	var fwd := -b.basis.z.normalized()
	var right := b.basis.x.normalized()
	var up := b.basis.y.normalized()
	var feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var hands: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var knee_pole: Array[Vector3] = [fwd, fwd]
	var elbow_pole: Array[Vector3] = [-fwd - right * 0.3, -fwd + right * 0.3]
	var st := body.pose
	if st != &"CLIMBING":
		_climb_ready = false
	if st == &"CLIMBING":
		_climb(delta, s, hips, shoulders, feet, hands)
		var n := body.climb_normal
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
			sole = (up * 0.6 + body.climb_normal * 0.4).normalized()
			toe = -body.climb_normal
		toe = (toe - sole * toe.dot(sole)).normalized()
		var bx := sole.cross(toe).normalized()
		boot.global_transform = Transform3D(Basis(bx, sole, -toe).scaled(Vector3.ONE * s),
				feet[i] - sole * FOOT_DROP * 0.3 * s + toe * 0.06 * s)


## The hair follows the head: it trails behind the head's motion and settles
## under gravity (whichever way the body leans), and is darker and flatter
## after time in the water.
func _hair_motion(b: Transform3D, delta: float) -> void:
	var hp := b * HEAD
	var vel := (hp - _head_prev) / maxf(delta, 1e-3) if _head_prev != Vector3.ZERO else Vector3.ZERO
	_head_prev = hp
	var inv := b.basis.orthonormalized().inverse()
	var target := (inv * (-vel)).limit_length(8.0) * 0.006 + inv * Vector3.DOWN * 0.03
	_sway = _sway.lerp(target, minf(1.0, 7.0 * delta))
	material.set_shader_parameter("sway", _sway)
	var in_water := body.pose == &"SWIMMING" or body.pose == &"TREADING" or body.pose == &"SINKING" or body.head_under
	_wet = minf(1.0, _wet + delta / 2.0) if in_water else maxf(0.0, _wet - delta / 40.0)
	material.set_shader_parameter("wet", _wet)


# --- walking ----------------------------------------------------------------------

func _walk(delta: float, s: float, hips: Array[Vector3], feet: Array[Vector3]) -> void:
	var leg := (THIGH + SHIN) * s
	if not _walk_ready:
		for i in 2:
			_feet[i] = _ground_below(hips[i], leg)
			_t[i] = -1.0
	var vel := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var speed := vel.length()
	var airborne := body.pose != &"WALKING"
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
	var n := body.climb_normal
	var up := (Vector3.UP - n * Vector3.UP.dot(n)).normalized()
	var right := up.cross(n).normalized()
	var ideal: Array[Vector3] = [
		shoulders[0] + up * 0.36 * s - right * 0.1 * s,
		shoulders[1] + up * 0.36 * s + right * 0.1 * s,
		hips[0] - up * 0.62 * s - right * 0.08 * s,
		hips[1] - up * 0.62 * s + right * 0.08 * s,
	]
	# lead with the limbs in the direction of travel
	var v := body.velocity
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
	q.exclude = [body.get_rid()]
	return body.get_world_3d().direct_space_state.intersect_ray(q)


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

static func _xf(pos: Vector3, scale_ := Vector3.ONE, rot := Vector3.ZERO) -> Transform3D:
	return Transform3D(Basis.from_euler(rot).scaled(scale_), pos)


func _limb_part(parent: Node3D, mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Limb"
	mi.mesh = mesh
	mi.material_override = material
	mi.top_level = true
	parent.add_child(mi, true)
	return mi


static func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = 16
	c.rings = 1
	return c


static func _sphere(r: float, segs := 16, rings := 8) -> SphereMesh:
	var sp := SphereMesh.new()
	sp.radius = r
	sp.height = r * 2.0
	sp.radial_segments = segs
	sp.rings = rings
	return sp


static func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 10
	c.rings = 2
	return c


static func _box(size: Vector3) -> BoxMesh:
	var bx := BoxMesh.new()
	bx.size = size
	return bx
