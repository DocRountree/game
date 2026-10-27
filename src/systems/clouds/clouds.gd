@tool
class_name Clouds
extends MultiMeshInstance3D
## Highly stylised cumulus: every cloud is a cluster of round puffs ("dots").
##
## The CPU only lays out the puffs once. The GPU (clouds.gdshader) moves the
## clouds with the wind, wraps the layer around the camera, and runs each
## cloud's life: base puffs condense first, the tower builds on top, then it
## evaporates from the top down and later re-forms with a new strength.
## Atmosphere feeds in the sunlight as it reaches the cloud layer, so clouds
## catch sunset colours, and stay lit a little after the sun has set below.

@export var area := 30000.0              ## Side of the square of sky wrapped around the camera (m); its edge lies beyond the horizon.
@export var curvature_radius := 38000.0  ## Exaggerated curvature: the layer sinks below the horizon ~10 km out.
@export var altitude := 1300.0           ## Cloud base (m).
@export var cloud_count := 1600
@export var puffs_per_cloud := 40       ## More puffs means smaller ones: overall cloud size stays the same.
@export var wind := Vector2(7.0, 2.5)    ## m/s.
@export var life_seconds := 150.0        ## Real seconds for one form-live-evaporate cycle.
@export_range(0.0, 1.0) var coverage := 0.6   ## Share of clouds active in a cycle.
@export var layout_seed := 7


func _ready() -> void:
	if not Engine.is_editor_hint():   # in game, density follows the quality settings
		cloud_count = QualitySettings.current().cloud_count
		puffs_per_cloud = QualitySettings.current().puffs_per_cloud
	_build()


func _build() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = layout_seed
	var n := cloud_count * puffs_per_cloud
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = n
	# puff radius shrinks with the puff count so a cloud's coverage stays the same
	var puff_scale := sqrt(14.0 / puffs_per_cloud)
	var buf := PackedFloat32Array()
	buf.resize(n * 20)   # per puff: 12 transform floats, 4 colour, 4 custom
	for c in cloud_count:
		var site := Vector2(rng.randf() * area, rng.randf() * area)
		var cloud_seed := rng.randf()
		var size := rng.randf_range(0.6, 1.5)
		for p in puffs_per_cloud:
			var order := float(p) / (puffs_per_cloud - 1)   # 0 condenses first (base), 1 last (top of the tower)
			var a := rng.randf() * TAU
			var spread := (1.0 - 0.7 * order) * rng.randf_range(0.3, 1.0) * 150.0 * size
			var offset := Vector3(cos(a) * spread, order * order * 170.0 * size + rng.randf() * 15.0,
					sin(a) * spread * 0.7)
			var radius := rng.randf_range(70.0, 110.0) * puff_scale * size * (1.0 - 0.3 * order)
			var o := (c * puffs_per_cloud + p) * 20
			buf[o] = radius        # rows of the 3x4 transform: uniform scale, puff offset
			buf[o + 3] = offset.x
			buf[o + 5] = radius
			buf[o + 7] = offset.y
			buf[o + 10] = radius
			buf[o + 11] = offset.z
			buf[o + 12] = clampf(offset.y / (200.0 * size), 0.0, 1.0)   # colour.r: height in the cloud
			buf[o + 15] = 1.0
			buf[o + 16] = site.x   # custom: cloud site, seed, formation order
			buf[o + 17] = site.y
			buf[o + 18] = cloud_seed
			buf[o + 19] = order
	mm.buffer = buf
	mm.custom_aabb = AABB(Vector3(-1e6, -1e5, -1e6), Vector3(2e6, 2e5, 2e6))
	multimesh = mm
	custom_aabb = mm.custom_aabb
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("area", area)
		mat.set_shader_parameter("curvature_radius", curvature_radius)
		mat.set_shader_parameter("altitude", altitude)
		mat.set_shader_parameter("wind", wind)
		mat.set_shader_parameter("life_seconds", life_seconds)
		mat.set_shader_parameter("coverage", coverage)


## Lighting from Atmosphere: sun direction, sunlight at cloud height, sky light.
func update_sky(sun_direction: Vector3, sun_colour: Vector3, ambient: Vector3) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("sun_direction", sun_direction)
	mat.set_shader_parameter("sun_colour", sun_colour)
	mat.set_shader_parameter("ambient", ambient)


## Weather: share of clouds that form, overcast fullness, and greyness (0..1).
func set_weather(coverage: float, fill: float, grey: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("coverage", coverage)
		mat.set_shader_parameter("fill", fill)
		mat.set_shader_parameter("grey", grey)


## Lightning: light the clouds around a point (amount 0 = no flash).
func set_flash(at: Vector3, amount: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("flash_pos", at)
		mat.set_shader_parameter("flash", amount)
