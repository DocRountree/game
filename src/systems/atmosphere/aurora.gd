@tool
class_name Aurora
extends MeshInstance3D
## Northern lights, as a 3D emission field above a round Earth (see
## aurora.gdshader), drawn on a sky dome. Rare at this latitude: each night has
## an independent `chance` (from the world seed, so a given night is always the
## same) of a display.
##
## Each display is rolled from the seed: how strong the storm is (strong ones
## reach overhead, or south of you), where the auroral oval sits, 1-3 curtains
## made of pillars (each with its own pillar spacing and crowding, ragged base
## height and softness, length, pace and colours: yellow-green to cyan, red or
## blue-violet tops, sometimes magenta), swirls that fold the curtains (S folds,
## spirals, folds within folds) and structureless glows. Through the night the
## oval drifts, curtains brighten and fade on their own, swirls wind and unwind,
## and pillars flicker.
##
## No crossing, by construction: curtains are stacked north to south in an
## "unwarped" plane with a gap of at least MIN_GAP between their fold envelopes,
## and the swirls that fold them are bijections of the plane (rotations about a
## centre by an angle that depends only on the distance from it).

const RADIUS := 2300.0
const MAX_CURTAINS := 4         ## Must match aurora.gdshader.
const MAX_SWIRLS := 5           ## Must match aurora.gdshader.
const MIN_GAP := 15.0           ## km between neighbouring curtains' fold envelopes.

@export_range(0.0, 1.0) var chance := 0.02    ## About one night in fifty.
@export var time_scale := 1.0   ## How fast the display moves and evolves (0 = frozen; for tuning).

var strength := 0.0             ## This night's display, 0 = none.
var style := {}                 ## This night's character: storm, oval, curtains (see _style_for).
var display_time := 0.0         ## Seconds of display animation (drives the shader).
var _night_id := -2147483648


func _ready() -> void:
	var dome := SphereMesh.new()
	dome.radius = RADIUS
	dome.height = RADIUS * 2.0
	dome.radial_segments = 48
	dome.rings = 24
	mesh = dome
	custom_aabb = AABB(Vector3.ONE * -RADIUS, Vector3.ONE * RADIUS * 2.0)


func _process(delta: float) -> void:
	display_time += delta * time_scale


## Whether night `night_id` (the day it began) has an aurora, and how strong.
func strength_for(night_id: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("aurora:%d" % night_id)
	return rng.randf_range(0.5, 1.0) if rng.randf() < chance else 0.0


## night: 0 by day, 1 at night; night_id: the day the current night began.
func update_sky(night: float, night_id: int) -> void:
	if night_id != _night_id:
		_night_id = night_id
		strength = strength_for(night_id)
		style = _style_for(night_id)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		global_position = cam.global_position
	visible = strength > 0.0 and night > 0.5
	var mat := material_override as ShaderMaterial
	if mat == null or not visible:
		return
	mat.set_shader_parameter("strength", strength * smoothstep(0.5, 1.0, night))
	mat.set_shader_parameter("clock", display_time)
	_push_curtains(mat)


# The night's character. Everything per curtain and per swirl is independent.
func _style_for(night_id: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("aurora-style:%d" % night_id)
	var storm := rng.randf()
	var curtains: Array[Dictionary] = []
	var count := 1 + int(rng.randf() < 0.45) + int(storm > 0.75 and rng.randf() < 0.4)
	for k in count:
		var high_base := rng.randf() < 0.15          # pillars that start high: no visible base
		var magenta_roll := rng.randf()
		curtains.append({
			"amplitude": rng.randf_range(5.0, 60.0),
			"gap": rng.randf_range(MIN_GAP, 150.0),
			"base": rng.randf_range(130.0, 160.0) if high_base else rng.randf_range(95.0, 120.0),
			"softness": rng.randf_range(10.0, 35.0),
			"decay": rng.randf_range(30.0, 160.0),
			"thickness": rng.randf_range(2.0, 10.0),
			"brightness": rng.randf_range(0.5, 1.0),
			"pillar_spacing": rng.randf_range(3.0, 14.0),
			"sheet": rng.randf_range(0.4, 0.6) if rng.randf() < 0.1 else rng.randf_range(0.0, 0.3),
			"ragged": rng.randf_range(5.0, 30.0),
			"magenta": rng.randf_range(0.8, 1.0) if magenta_roll < 0.1 else (rng.randf_range(0.3, 0.6) if magenta_roll < 0.35 else 0.0),
			"red": rng.randf_range(0.2, 1.0) * (0.5 + storm) if rng.randf() < 0.5 else 0.0,
			"blue": rng.randf_range(0.2, 0.9) if rng.randf() < 0.45 else 0.0,
			"hue": rng.randf(),
			"green_top": rng.randf_range(140.0, 230.0),
			"seed": rng.randf() * 100.0,
			"pace": rng.randf_range(0.3, 1.8),
			"west": -rng.randf_range(400.0, 1800.0),
			"east": rng.randf_range(400.0, 1800.0),
			"fold_scale": rng.randf_range(0.5, 2.0),
			"swell_rate": rng.randf_range(0.004, 0.03),   # how fast it brightens and fades
		})
	# swirls that fold the curtains; some nest a smaller one inside
	var swirls: Array[Dictionary] = []
	var n_swirls := rng.randi_range(0, 2) + int(storm > 0.5) + int(storm > 0.8)
	for i in n_swirls:
		if swirls.size() >= MAX_SWIRLS:
			break
		var big := {
			"curtain": rng.randi_range(0, count - 1),
			"x": rng.randf_range(-700.0, 700.0), "dy": rng.randf_range(-40.0, 40.0),
			"radius": rng.randf_range(50.0, 250.0),
			"angle": rng.randf_range(0.8, 3.5) * (1.0 if rng.randf() < 0.5 else -1.0),
			"sway": rng.randf_range(100.0, 500.0), "rate": rng.randf_range(0.002, 0.012),
			"seed": rng.randf() * 100.0,
		}
		swirls.append(big)
		if rng.randf() < 0.4 and swirls.size() < MAX_SWIRLS:
			swirls.append({
				"curtain": big.curtain, "parent": swirls.size() - 1,
				"x": rng.randf_range(-0.3, 0.3) * big.radius, "dy": rng.randf_range(-0.3, 0.3) * big.radius,
				"radius": big.radius * rng.randf_range(0.2, 0.45),
				"angle": rng.randf_range(1.0, 3.0) * (1.0 if rng.randf() < 0.5 else -1.0),
				"sway": 0.0, "rate": rng.randf_range(0.004, 0.02), "seed": rng.randf() * 100.0,
			})
	return {
		"storm": storm,
		"oval": lerpf(1100.0, -200.0, pow(storm, 1.3)),   # km north of the equatorward curtain
		"oval_drift": rng.randf_range(60.0, 300.0),
		"red_glow": rng.randf() * (0.3 + 0.7 * storm) if rng.randf() < 0.3 else 0.0,
		"green_patches": rng.randf() * 0.6 if rng.randf() < 0.5 else 0.0,
		"glow_seed": rng.randf() * 100.0,
		"curtains": curtains,
		"swirls": swirls,
	}


func _push_curtains(mat: ShaderMaterial) -> void:
	var c := _curtains_now()
	for key: String in c:
		mat.set_shader_parameter(key, c[key])


# Every curtain's and swirl's shader parameters at the current display time.
func _curtains_now() -> Dictionary:
	var t := display_time
	var curtains: Array = style.get("curtains", [])
	var shape: Array[Vector4] = []
	var glow: Array[Vector4] = []
	var colour: Array[Vector4] = []
	var look: Array[Vector4] = []
	var extent: Array[Vector4] = []
	var lines: Array[float] = []
	# the oval drifts north and south; curtains stack poleward from it, never crossing
	var north: float = style.get("oval", 0.0) + style.get("oval_drift", 0.0) * (_smooth_noise(t * 0.003 + 5.0) - 0.5) * 2.0
	for k in MAX_CURTAINS:
		if k >= curtains.size():
			for a: Array in [shape, glow, colour, look, extent]:
				a.append(Vector4.ZERO)
			continue
		var c: Dictionary = curtains[k]
		var amp: float = c.amplitude
		if k > 0:
			var gap: float = c.gap * (0.6 + 0.8 * _smooth_noise(t * 0.005 + c.seed))
			north += curtains[k - 1].amplitude + maxf(gap, MIN_GAP) + amp
		lines.append(north)
		var swell := smoothstep(0.15, 0.75, _smooth_noise(t * c.swell_rate + c.seed * 3.0))
		shape.append(Vector4(north, amp, c.base, c.softness))
		glow.append(Vector4(c.decay, c.thickness, c.brightness * swell, c.pillar_spacing))
		colour.append(Vector4(c.magenta, c.red, c.blue, c.hue))
		look.append(Vector4(c.green_top, c.seed, c.pace, c.sheet))
		extent.append(Vector4(c.west, c.east, c.fold_scale, c.ragged))
	# swirls follow their curtain, sway along it, and wind and unwind
	var swirl_data: Array[Vector4] = []
	var centres: Array[Vector2] = []
	for i in MAX_SWIRLS:
		var sw: Dictionary = (style.get("swirls", []) as Array)[i] if i < (style.get("swirls", []) as Array).size() else {}
		if sw.is_empty():
			swirl_data.append(Vector4(0.0, 0.0, 1.0, 0.0))
			continue
		var centre: Vector2
		if sw.has("parent"):
			centre = centres[sw.parent] + Vector2(sw.x, sw.dy)
		else:
			centre = Vector2(sw.x + sw.sway * sin(t * sw.rate + sw.seed), lines[sw.curtain] + sw.dy)
		centres.append(centre)
		var wind := lerpf(0.15, 1.0, _smooth_noise(t * sw.rate * 2.0 + sw.seed * 7.0))
		swirl_data.append(Vector4(centre.x, centre.y, sw.radius, sw.angle * wind))
	return {
		"curtain_count": curtains.size(), "c_shape": shape, "c_glow": glow, "c_color": colour,
		"c_style": look, "c_extent": extent,
		"swirl_count": centres.size(), "swirls": swirl_data,
		"red_glow": style.get("red_glow", 0.0) * (0.6 + 0.8 * _smooth_noise(t * 0.006 + 2.0)),
		"green_patches": style.get("green_patches", 0.0), "glow_seed": style.get("glow_seed", 0.0),
	}


## Each curtain's foot (km north) and fold amplitude right now, for night_id; for tests.
func curtain_feet(night_id: int) -> Array[Vector2]:
	style = _style_for(night_id)
	var shape: Array = _curtains_now().c_shape
	var out: Array[Vector2] = []
	for k in (style.curtains as Array).size():
		out.append(Vector2(shape[k].x, shape[k].y))
	return out


## Swirl maths, mirroring aurora.gdshader: unwarp undoes the swirls (applied in
## order) by turning back through each, last first. Both are exact bijections.
static func unwarp_point(q: Vector2, swirls: Array[Vector4]) -> Vector2:
	for i in range(swirls.size() - 1, -1, -1):
		q = _turn(q, swirls[i], -1.0)
	return q


static func warp_point(q: Vector2, swirls: Array[Vector4]) -> Vector2:
	for sw in swirls:
		q = _turn(q, sw, 1.0)
	return q


static func _turn(q: Vector2, sw: Vector4, direction: float) -> Vector2:
	var d := q - Vector2(sw.x, sw.y)
	var r := d.length() / sw.z
	return Vector2(sw.x, sw.y) + d.rotated(direction * sw.w * exp(-r * r))


static func _smooth_noise(x: float) -> float:
	var i := floorf(x)
	var f := x - i
	var a := fposmod(sin(i * 127.1) * 43758.5453, 1.0)
	var b := fposmod(sin((i + 1.0) * 127.1) * 43758.5453, 1.0)
	return lerpf(a, b, f * f * (3.0 - 2.0 * f))
