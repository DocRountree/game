@tool
class_name Clouds
extends MeshInstance3D
## Volumetric clouds (see clouds.gdshader): a ray-marched cloud layer over the
## round Earth, drawn on a dome around the camera. This node owns the noise
## textures and passes in lighting (from Atmosphere), weather (coverage,
## overcast fill and greyness, from Weather) and lightning flashes.
##
## Cost scales with QualitySettings.cloud_steps (samples per view ray).

const DOME_RADIUS := 2000.0     ## In front of the aurora (2300 m) and stars.

@export var altitude := 1500.0              ## Cloud base (m); also where lightning leaves the cloud.
@export var curvature_radius := 6371000.0   ## The real Earth (for lightning placement).
@export var wind := Vector2(7.0, 2.5)       ## m/s.

var _shape: NoiseTexture3D
var _detail: NoiseTexture3D


func _ready() -> void:
	var dome := SphereMesh.new()
	dome.radius = DOME_RADIUS
	dome.height = DOME_RADIUS * 2.0
	dome.radial_segments = 32
	dome.rings = 16
	mesh = dome
	custom_aabb = AABB(Vector3.ONE * -DOME_RADIUS, Vector3.ONE * DOME_RADIUS * 2.0)
	_shape = _noise(96, FastNoiseLite.TYPE_PERLIN, 5, 2.0)
	_detail = _noise(32, FastNoiseLite.TYPE_CELLULAR, 3, 4.0)
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("shape_noise", _shape)
		mat.set_shader_parameter("detail_noise", _detail)
		mat.set_shader_parameter("base_altitude", altitude)
		mat.set_shader_parameter("wind", wind)
		if not Engine.is_editor_hint():
			mat.set_shader_parameter("steps", QualitySettings.current().cloud_steps)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		global_position = cam.global_position


static func _noise(size: int, kind: FastNoiseLite.NoiseType, octaves: int, frequency_cells: float) -> NoiseTexture3D:
	var n := FastNoiseLite.new()
	n.noise_type = kind
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	n.frequency = frequency_cells / size
	n.seed = 7 + size
	if kind == FastNoiseLite.TYPE_CELLULAR:
		n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	var tex := NoiseTexture3D.new()
	tex.width = size
	tex.height = size
	tex.depth = size
	tex.seamless = true
	tex.normalize = true
	tex.noise = n
	return tex


## Lighting from Atmosphere: sun direction, sunlight at cloud height, sky light.
func update_sky(sun_direction: Vector3, sun_colour: Vector3, ambient: Vector3) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("sun_direction", sun_direction)
	mat.set_shader_parameter("sun_colour", sun_colour)
	mat.set_shader_parameter("ambient", ambient)


## Weather: how much of the sky is cloud, overcast fullness, and greyness (0..1).
func set_weather(coverage: float, fill: float, grey: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("coverage", coverage)
		mat.set_shader_parameter("fill", fill)
		mat.set_shader_parameter("grey", grey)
	visible = coverage > 0.001


## Lightning: light the clouds around a point (amount 0 = no flash).
func set_flash(at: Vector3, amount: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("flash_pos", at)
		mat.set_shader_parameter("flash", amount)
