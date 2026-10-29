class_name HairBuilder
extends RefCounted
## Hair and facial hair as geometry grown from CharacterTraits: a scalp cap
## (its hairline high at the front, down over the ears when the hair is long)
## and clumps of tapered tubes rooted on it. Length sets how far each clump
## runs (it falls under gravity, sliding down the head and round the neck and
## pack, never through them); curl turns it to a helix and shortens it (curly
## hair is springy) and fattens the whole head of hair; a ponytail or bun
## gathers the clumps' lengths into one place behind the head. Everything is
## in the head's frame (metres, the head's centre the origin, -Z the face), and
## the roots are the same whatever the settings, so dragging a slider moves
## the hair rather than shuffling it.

const HR := Vector3(0.114, 0.1296, 0.12)   ## The head's radii.
const CANDIDATES := 130                     ## Points tried for roots (about 75 land on the scalp).
const MAX_SEGMENTS := 13
const SIDES := 3
const TWO_PI_GOLDEN := 2.39996323

# the body's solids in the head's frame (CharacterRig.build)
const NECK := Vector3(0.0, -0.11, 0.005)    ## Axis point; radius 0.055 above y -0.2.
const TORSO_TOP := -0.19
const TORSO_BOTTOM := -0.63
const PACK_CENTRE := Vector3(0.0, -0.38, 0.17)
const PACK_HALF := Vector3(0.14, 0.17, 0.065)
const ROLL_CENTRE := Vector3(0.0, -0.17, 0.175)


## How far the hair stands off the scalp (m): a thin film when it's cropped,
## a deep cap when it's long or curly.
static func thickness(t: CharacterTraits) -> float:
	if t.hair_length < 0.02 and t.hair_curl < 0.5:
		return 0.0012
	var len_f := t.hair_length
	return 0.004 + 0.012 * smoothstep(0.0, 0.3, len_f) + 0.022 * t.hair_curl * smoothstep(0.0, 0.2, len_f)


## The polar angle (from the crown) the scalp's hair reaches at azimuth phi
## (0 the front, PI the back).
static func hairline(phi: float, len_f: float) -> float:
	var front := smoothstep(0.2, 1.0, cos(phi))
	var side := smoothstep(0.3, 0.9, absf(sin(phi)))
	var ears := smoothstep(0.1, 0.4, len_f)
	return deg_to_rad(lerpf(118.0, 98.0 + 14.0 * ears, side) - 44.0 * front)


static func _dir(theta: float, phi: float) -> Vector3:
	return Vector3(sin(theta) * sin(phi), cos(theta), -sin(theta) * cos(phi))


static func _on_head(theta: float, phi: float, off: float) -> Vector3:
	var d := _dir(theta, phi)
	return HR * d + (d / HR).normalized() * off


## Move p out of the head, neck, torso, shoulders, pack and bedroll (each
## inflated by `margin`), the cheapest way out.
static func push(p: Vector3, margin: float) -> Vector3:
	# the head: back out along the radius
	var hm := HR + Vector3.ONE * margin
	var k := (p / hm).length()
	if k < 1.0 and k > 1e-4:
		p /= k
	if p.y > -0.1:   # (above the shoulders and the bedroll: only the head and neck)
		var dxz := Vector2(p.x - NECK.x, p.z - NECK.z)
		var rn := 0.055 + margin
		if p.y < -0.06 and dxz.length() < rn and dxz.length() > 1e-4:
			dxz = dxz / dxz.length() * rn
			p.x = NECK.x + dxz.x
			p.z = NECK.z + dxz.y
		return p
	# torso: an elliptical cylinder, widest at the shoulders
	if p.y > TORSO_BOTTOM and p.y < TORSO_TOP:
		var rx := lerpf(0.155, 0.19, inverse_lerp(TORSO_BOTTOM, TORSO_TOP, p.y)) + margin
		var rz := rx * 0.68
		var e := Vector2(p.x / rx, (p.z - 0.005) / rz)
		var el := e.length()
		if el < 1.0 and el > 1e-4:
			e /= el
			p.x = e.x * rx
			p.z = 0.005 + e.y * rz
	# shoulders
	for sx: float in [-1.0, 1.0]:
		var c := Vector3(0.2 * sx, -0.2, 0.005)
		var o := p - c
		var r := Vector3(0.075 + margin, 0.0675 + margin, 0.0675 + margin)
		var sk := (o / r).length()
		if sk < 1.0 and sk > 1e-4:
			p = c + o / sk
	# the pack: out of the nearest face
	var q := p - PACK_CENTRE
	var h := PACK_HALF + Vector3.ONE * margin
	if absf(q.x) < h.x and absf(q.y) < h.y and absf(q.z) < h.z:
		var dx := h.x - absf(q.x)
		var dy := h.y - absf(q.y)
		var dz := h.z - absf(q.z)
		if dz <= dx and dz <= dy:
			p.z = PACK_CENTRE.z + signf(q.z if absf(q.z) > 1e-4 else -1.0) * h.z
		elif dx <= dy:
			p.x = PACK_CENTRE.x + signf(q.x if absf(q.x) > 1e-4 else 1.0) * h.x
		else:
			p.y = PACK_CENTRE.y + h.y
	# the bedroll on top of it (along x)
	var rr := Vector2(p.y - ROLL_CENTRE.y, p.z - ROLL_CENTRE.z)
	if absf(p.x) < 0.17 + margin and rr.length() < 0.055 + margin and rr.length() > 1e-4:
		rr = rr / rr.length() * (0.055 + margin)
		p.y = ROLL_CENTRE.y + rr.x
		p.z = ROLL_CENTRE.z + rr.y
	return p


## Hair that would hang in front of the face is moved aside, so long hair
## frames the face rather than covering it.
static func _off_face(p: Vector3) -> Vector3:
	if p.z < -0.03 and p.y > -0.16 and p.y < 0.07 and absf(p.x) < 0.09:
		p.x = 0.09 * (signf(p.x) if absf(p.x) > 1e-4 else 1.0)
	return p


static func _frame(t: Vector3) -> Array[Vector3]:
	var ref := Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT
	var u := t.cross(ref).normalized()
	return [u, t.cross(u)]


## The scalp and its clumps, in colour slot P_HAIR (P_STUBBLE for cropped
## hair).
static func add_hair(mb: MeshBuilder, t: CharacterTraits) -> void:
	var len_f := t.hair_length
	var curl := t.hair_curl
	var thick := thickness(t)
	var hatted := t.hat != "none"
	if hatted:
		thick = minf(thick, 0.016)   # (pressed flat under a hat)
	var shaved := len_f < 0.02 and curl < 0.5
	var slot := CharacterTraits.P_STUBBLE if shaved else CharacterTraits.P_HAIR
	# the scalp
	var rings := 9
	var cols := 25
	var pts := PackedVector3Array()
	for r in rings:
		for c in cols:
			var phi := TAU * c / (cols - 1) - PI
			var th := hairline(phi, len_f) * float(r) / (rings - 1)
			pts.append(_on_head(th, phi, thick))
	mb.add_grid(pts, rings, cols, slot, 0.0, true)
	if shaved:
		return
	# the clumps
	var style := "ponytail" if t.has_accessory("ponytail") else ("bun" if t.has_accessory("bun") else "")
	if style == "bun" and len_f > 0.15:   # (its body: the clumps wind round it)
		var ball := SphereMesh.new()
		ball.radius = 0.02 + 0.03 * len_f
		ball.height = ball.radius * 2.0
		ball.radial_segments = 10
		ball.rings = 5
		mb.add_mesh(ball, Transform3D(Basis(), Vector3(0.0, 0.06, 0.13 + 0.01 * len_f)), CharacterTraits.P_HAIR)
	var rng := RandomNumberGenerator.new()
	for i in CANDIDATES:
		var z := 1.0 - 2.0 * (i + 0.5) / CANDIDATES
		var theta := acos(z)
		var phi := fmod(i * TWO_PI_GOLDEN, TAU) - PI
		if theta > hairline(phi, len_f) - 0.14:
			continue
		rng.seed = 1000 + i
		var length := len_f * 0.6 * rng.randf_range(0.85, 1.15) * (1.0 - 0.4 * curl * curl)
		var front := cos(phi) > 0.45 and theta > 0.55
		if front:
			length *= 0.12   # (a fringe, not a veil)
		if length < 0.018:
			continue
		var segs := clampi(ceili(length / 0.04) + int(curl * 8.0 * minf(length / 0.15, 1.0)), 2, MAX_SEGMENTS)
		var seg := length / segs
		var normal := (_dir(theta, phi) / HR).normalized()
		var p := _on_head(theta, phi, thick * 0.5)
		var lf := minf(len_f * 1.5, 1.0)
		var r0 := 0.011 + 0.006 * curl
		var margin := maxf(0.005 + thick, r0 + 0.002)
		var path := PackedVector3Array([p])
		# (combed back and to the sides, away from the face)
		var comb := Vector3(p.x, 0.0, p.z + 0.08)
		comb = comb.normalized() if comb.length() > 1e-4 else Vector3.BACK
		# (leaving the scalp lying along it rather than standing out from it,
		# more so the shorter it is)
		var dir := (normal * lerpf(0.3, 0.7, lf) + comb * 0.4 + Vector3.DOWN * 0.4).normalized()
		for s in range(1, segs + 1):
			var f := float(s) / segs
			var g := ((0.15 + 0.35 * lf) + (0.55 - 0.1 * lf) * f) * (1.0 - 0.4 * curl)
			dir = (dir * (1.0 - g) + Vector3.DOWN * g + comb * 0.5 * (1.0 - f)).normalized()
			p = _off_face(push(p + dir * seg, margin))
			if hatted:
				p.y = minf(p.y, 0.15)
			path.append(p)
		var gathered := 0
		if style != "" and length > 0.08:
			# (drawn back from the scalp into it: a bun at once, a ponytail
			# from a little way along)
			var s0 := 1 if style == "bun" else maxi(1, int(segs * 0.2))
			gathered = segs if style == "bun" else 0
			var ang := rng.randf() * TAU
			for s in range(s0, segs + 1):
				var f := float(s - s0) / maxi(segs - s0, 1)
				var w := smoothstep(s0 - 1.0, s0 + 2.0, float(s))
				var tg: Vector3
				if style == "ponytail":
					var drop := f * length * 0.8
					# (out over the bedroll, then down the pack)
					tg = Vector3(0.0, -0.005 - drop, 0.14 + 0.12 * clampf(drop / 0.12, 0.0, 1.0)) \
							+ Vector3(cos(ang), 0.0, sin(ang)) * 0.012 * (1.0 - f)
				else:
					var a2 := ang + f * 5.0
					tg = Vector3(0.0, 0.06, 0.13) + Vector3(cos(a2), sin(a2) * 0.8, sin(a2 * 0.5 + ang) * 0.6) * 0.038
				path[s] = path[s].lerp(tg, w)
		if curl > 0.05:
			var amp := curl * 0.03
			var turns := lerpf(0.6, segs / 5.0, curl)
			var base := path.duplicate()
			var phase := rng.randf() * TAU
			for s in range(1, path.size() if gathered == 0 else gathered + 1):
				var f := float(s) / segs
				var t3 := (base[mini(s + 1, base.size() - 1)] - base[s - 1]).normalized()
				var fr := _frame(t3)
				var a := TAU * turns * f + phase
				path[s] = _off_face(push(base[s] + (fr[0] * cos(a) + fr[1] * sin(a)) * amp * (0.3 + 0.7 * f), margin))
				if hatted:
					path[s].y = minf(path[s].y, 0.15)
		var radii := PackedFloat32Array()
		for s in path.size():
			radii.append(lerpf(r0, r0 * 0.35, float(s) / (path.size() - 1)))
		mb.add_tube(path, radii, SIDES, CharacterTraits.P_HAIR, 1.0 - 0.5 * curl)


## Whether the region of the face where a beard of this kind grows holds
## (theta, phi): the moustache above the mouth, the goatee on the chin, the
## beard on the jaw and cheeks.
static func _beard_region(style: int, theta: float, phi: float) -> bool:
	var a := absf(phi)
	var must := a < 0.5 and theta > 1.8 and theta < 1.93
	match style:
		CharacterTraits.FacialHair.MOUSTACHE:
			return must
		CharacterTraits.FacialHair.GOATEE:
			return must or (a < 0.38 and theta > 1.98 and theta < 2.3)
		CharacterTraits.FacialHair.BEARD, CharacterTraits.FacialHair.STUBBLE:
			return must or (a < 1.75 and theta > 1.72 and theta < 2.5 and not (a < 0.45 and theta > 1.93 and theta < 1.99))
	return false


static func add_facial_hair(mb: MeshBuilder, t: CharacterTraits) -> void:
	var style := t.facial_hair
	if style == CharacterTraits.FacialHair.NONE:
		return
	# the skin shaded: a patch just over the face
	var th_step := 0.065
	var ph_step := 0.14
	var nth := int((2.5 - 1.72) / th_step) + 1
	var nph := int(2.0 * 1.75 / ph_step) + 1
	var pts := PackedVector3Array()
	var ok := PackedByteArray()
	for r in nth:
		for c in nph:
			var th := 1.72 + r * th_step
			var ph := -1.75 + c * ph_step
			pts.append(_on_head(th, ph, 0.0013))
			ok.append(1 if _beard_region(style, th, ph) else 0)
	# (only the cells wholly inside the region are drawn)
	var base := mb.verts.size()
	var c0 := Color(CharacterTraits.P_STUBBLE / 255.0, 0.0, 0.0, 1.0)
	for i in pts.size():
		mb.verts.append(pts[i])
		mb.normals.append((pts[i] / (HR * HR)).normalized())
		mb.colors.append(c0)
	for r in nth - 1:
		for c in nph - 1:
			var a := r * nph + c
			if ok[a] and ok[a + 1] and ok[a + nph] and ok[a + nph + 1]:
				mb.idx.append_array([base + a, base + a + 1, base + a + nph, base + a + 1, base + a + nph + 1, base + a + nph])
	if style == CharacterTraits.FacialHair.STUBBLE:
		return
	var max_len := 0.05 if style == CharacterTraits.FacialHair.MOUSTACHE else 0.12
	var length := 0.012 + (max_len - 0.012) * t.facial_hair_length
	var rng := RandomNumberGenerator.new()
	var th := 1.76
	while th < 2.46:
		var ph := -1.7
		while ph < 1.7:
			if _beard_region(style, th, ph):
				rng.seed = int(th * 997.0) * 31 + int((ph + 2.0) * 389.0)
				var tl := length * rng.randf_range(0.8, 1.15)
				if th > 2.3 or absf(ph) > 1.3:
					tl *= 0.7
				var segs := clampi(ceili(tl / 0.03), 1, 4)
				var normal := (_dir(th, ph) / HR).normalized()
				var p := _on_head(th + rng.randf_range(-0.03, 0.03), ph + rng.randf_range(-0.04, 0.04), 0.002)
				var dir := normal
				var path := PackedVector3Array([p])
				for s in segs:
					dir = (dir * 0.6 + Vector3.DOWN * 0.45 + Vector3(0.0, 0.0, -0.05)).normalized()
					p += dir * (tl / segs)
					p = push(p, 0.004)
					path.append(p)
				var radii := PackedFloat32Array()
				for s in path.size():
					radii.append(lerpf(0.0065, 0.0025, float(s) / (path.size() - 1)))
				mb.add_tube(path, radii, SIDES, CharacterTraits.P_HAIR, 0.15)
			ph += 0.2
		th += 0.15
