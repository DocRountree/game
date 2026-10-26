@tool
class_name Aurora
extends MeshInstance3D
## Northern lights, as a 3D emission field above a round Earth (see
## aurora.gdshader), drawn on a sky dome. Rare at this latitude: each night has
## an independent `chance` (from the world seed, so a given night is always the
## same) of a display.
##
## Each display is rolled from the seed: how strong the storm is (strong ones
## reach overhead, or south of you), where the auroral oval sits, and 1-6
## curtains, each with its own folds, pace, length, base height and softness,
## rays, thickness and colours (pink fringe, green, red, violet, white cores),
## plus structureless glows. Through the night the oval drifts, curtains
## brighten and fade on their own, and their folds and rays move. The curtains
## are stacked north to south with a gap of at least MIN_GAP between their
## fold envelopes, so they never cross.

const RADIUS := 2300.0
const MAX_CURTAINS := 6         ## Must match aurora.gdshader.
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


# The night's character. Everything per curtain is independent.
func _style_for(night_id: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("aurora-style:%d" % night_id)
	var storm := rng.randf()
	var curtains: Array[Dictionary] = []
	var count := clampi(1 + rng.randi_range(0, 2) + int(storm * 3.0), 1, MAX_CURTAINS)
	for k in count:
		var high_base := rng.randf() < 0.2          # rays that start high: no visible base
		curtains.append({
			"amplitude": rng.randf_range(10.0, 110.0),
			"gap": rng.randf_range(MIN_GAP, 160.0),
			"base": rng.randf_range(135.0, 170.0) if high_base else rng.randf_range(95.0, 120.0),
			"softness": rng.randf_range(2.0, 15.0),
			"decay": rng.randf_range(25.0, 150.0),
			"thickness": rng.randf_range(1.0, 6.0),
			"brightness": rng.randf_range(0.4, 1.0),
			"rays": rng.randf() * rng.randf() * 1.2 if rng.randf() < 0.3 else rng.randf_range(0.3, 1.0),
			"pink": rng.randf_range(0.3, 1.0) if rng.randf() < 0.35 else 0.0,
			"red": pow(rng.randf(), 2.0) * (0.3 + 0.7 * storm),   # usually little; strong on some
			"violet": rng.randf_range(0.2, 0.8) if rng.randf() < 0.4 else 0.0,
			"white": rng.randf_range(0.2, 0.6) if rng.randf() < 0.3 else 0.0,
			"green_top": rng.randf_range(150.0, 220.0),
			"seed": rng.randf() * 100.0,
			"pace": rng.randf_range(0.3, 2.0),
			"ray_spacing": rng.randf_range(2.0, 12.0),
			"west": -rng.randf_range(400.0, 1800.0),
			"east": rng.randf_range(400.0, 1800.0),
			"fold_scale": rng.randf_range(0.5, 2.0),
			"patchiness": rng.randf_range(0.0, 0.8),
			"swell_rate": rng.randf_range(0.004, 0.03),   # how fast it brightens and fades
		})
	return {
		"storm": storm,
		"oval": lerpf(1100.0, -200.0, pow(storm, 1.3)),   # km north of the equatorward curtain
		"oval_drift": rng.randf_range(60.0, 300.0),
		"red_glow": rng.randf() * (0.3 + 0.7 * storm) if rng.randf() < 0.4 else 0.0,
		"green_patches": rng.randf() * 0.6 if rng.randf() < 0.5 else 0.0,
		"glow_seed": rng.randf() * 100.0,
		"curtains": curtains,
	}


func _push_curtains(mat: ShaderMaterial) -> void:
	var c := _curtains_now()
	for key: String in c:
		mat.set_shader_parameter(key, c[key])


# Every curtain's shader parameters at the current display time.
func _curtains_now() -> Dictionary:
	var t := display_time
	var curtains: Array = style.get("curtains", [])
	var shape: Array[Vector4] = []
	var glow: Array[Vector4] = []
	var colour: Array[Vector4] = []
	var look: Array[Vector4] = []
	var extent: Array[Vector4] = []
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
		var swell := smoothstep(0.15, 0.75, _smooth_noise(t * c.swell_rate + c.seed * 3.0))
		shape.append(Vector4(north, amp, c.base, c.softness))
		glow.append(Vector4(c.decay, c.thickness, c.brightness * swell, c.rays))
		colour.append(Vector4(c.pink, c.red, c.violet, c.white))
		look.append(Vector4(c.green_top, c.seed, c.pace, c.ray_spacing))
		extent.append(Vector4(c.west, c.east, c.fold_scale, c.patchiness))
	return {
		"curtain_count": curtains.size(), "c_shape": shape, "c_glow": glow, "c_color": colour,
		"c_style": look, "c_extent": extent,
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


static func _smooth_noise(x: float) -> float:
	var i := floorf(x)
	var f := x - i
	var a := fposmod(sin(i * 127.1) * 43758.5453, 1.0)
	var b := fposmod(sin((i + 1.0) * 127.1) * 43758.5453, 1.0)
	return lerpf(a, b, f * f * (3.0 - 2.0 * f))
