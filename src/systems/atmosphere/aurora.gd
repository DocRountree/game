@tool
class_name Aurora
extends MeshInstance3D
## Northern lights over the northern horizon, green at the lower edge shading
## to violet above. Rare at this latitude: each night has an independent
## `chance` (from the world seed, so a given night is always the same) of an
## aurora. Every display has its own character: folding curtains (ripples),
## columns of rays (pillars) or a mix, with its own number of bands, height,
## folding and pace, and the shader keeps it evolving through the night.

const RADIUS := 2300.0
const ARC_DEGREES := 150.0      ## Width of the display, centred on north.
const LOW_DEGREES := 2.0        ## Elevation of the curtains' lower edge.
const HIGH_DEGREES := 40.0

@export_range(0.0, 1.0) var chance := 0.02    ## About one night in fifty.
@export var time_scale := 1.0   ## How fast the display moves and evolves (0 = frozen; for tuning).

var strength := 0.0             ## This night's display, 0 = none.
var style := {}                 ## This night's character (see _style_for).
var display_time := 0.0         ## Seconds of display animation (drives the shader).
var _night_id := -2147483648


func _ready() -> void:
	mesh = _build_arc()
	custom_aabb = AABB(Vector3.ONE * -RADIUS, Vector3.ONE * RADIUS * 2.0)


## Whether night `night_id` (the day it began) has an aurora, and how strong.
func strength_for(night_id: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("aurora:%d" % night_id)
	return rng.randf_range(0.5, 1.0) if rng.randf() < chance else 0.0


func _process(delta: float) -> void:
	display_time += delta * time_scale


## night: 0 by day, 1 at night; night_id: the day the current night began.
func update_sky(night: float, night_id: int) -> void:
	if night_id != _night_id:
		_night_id = night_id
		strength = strength_for(night_id)
		style = _style_for(night_id)
		var m := material_override as ShaderMaterial
		if m:
			for key: String in style:
				m.set_shader_parameter(key, style[key])
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		global_position = cam.global_position
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("strength", strength * smoothstep(0.5, 1.0, night))
		mat.set_shader_parameter("clock", display_time)
	visible = strength > 0.0 and night > 0.5


# How a night's display looks: sometimes curtains, sometimes pillars, often both.
func _style_for(night_id: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("aurora-style:%d" % night_id)
	var kind := rng.randi_range(0, 2)    # 0 ripples, 1 pillars, 2 both
	return {
		"ripples": [1.0, rng.randf_range(0.0, 0.25), rng.randf_range(0.5, 1.0)][kind],
		"pillars": [rng.randf_range(0.0, 0.25), 1.0, rng.randf_range(0.5, 1.0)][kind],
		"bands": float(rng.randi_range(1, 3)),
		"base_height": rng.randf_range(0.06, 0.2),
		"fold_scale": rng.randf_range(0.6, 1.8),
		"drift": rng.randf_range(0.5, 1.6),
		"seed": rng.randf() * 100.0,
	}


# A curved band of quads around the north, UV.x along it, UV.y upward.
func _build_arc() -> ArrayMesh:
	var segs := 96
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var low := deg_to_rad(LOW_DEGREES)
	var high := deg_to_rad(HIGH_DEGREES)
	for i in segs + 1:
		var u := float(i) / segs
		var az := deg_to_rad((u - 0.5) * ARC_DEGREES)
		for e: float in [low, high]:
			verts.append(Vector3(sin(az) * cos(e), sin(e), -cos(az) * cos(e)) * RADIUS)
			uvs.append(Vector2(u, 0.0 if e == low else 1.0))
	var idx := PackedInt32Array()
	for i in segs:
		var a := i * 2
		idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
