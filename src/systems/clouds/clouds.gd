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

@export var area := 24000.0              ## Side of the square of sky wrapped around the camera (m); big enough to reach low over the horizon.
@export var altitude := 1300.0           ## Cloud base (m).
@export var cloud_count := 1000
@export var puffs_per_cloud := 14
@export var wind := Vector2(7.0, 2.5)    ## m/s.
@export var life_seconds := 150.0        ## Real seconds for one form-live-evaporate cycle.
@export_range(0.0, 1.0) var coverage := 0.6   ## Share of clouds active in a cycle.
@export var layout_seed := 7


func _ready() -> void:
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
			var radius := rng.randf_range(70.0, 110.0) * size * (1.0 - 0.3 * order)
			var i := c * puffs_per_cloud + p
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * radius), offset))
			mm.set_instance_custom_data(i, Color(site.x, site.y, cloud_seed, order))
			mm.set_instance_color(i, Color(clampf(offset.y / (200.0 * size), 0.0, 1.0), 0.0, 0.0))
	mm.custom_aabb = AABB(Vector3(-1e6, -1e5, -1e6), Vector3(2e6, 2e5, 2e6))
	multimesh = mm
	custom_aabb = mm.custom_aabb
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("area", area)
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
