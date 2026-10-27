@tool
class_name Clouds
extends MeshInstance3D
## Volumetric clouds (see clouds.gdshader): a ray-marched cloud layer over the
## round Earth, drawn on a dome around the camera. This node owns the noise
## textures and passes in lighting (from Atmosphere), weather (coverage,
## thunderhead mix and greyness, from Weather) and lightning flashes.
##
## Cost scales with QualitySettings.cloud_steps (samples per view ray).

const DOME_RADIUS := 2000.0     ## In front of the aurora (2300 m) and stars.

@export var altitude := 1500.0              ## Cloud base (m); also where lightning leaves the cloud.
@export var curvature_radius := 6371000.0   ## The real Earth (for lightning placement).
@export var wind := Vector2(7.0, 2.5)       ## m/s.

const CELL_TILE := 160000.0     ## m: thunderhead cells repeat on this square, wrapped around the camera.
const MAX_CELLS := 16           ## Must match clouds.gdshader.

## Thunderhead cells this frame: (x, z, tower radius, top altitude), world metres.
var cells: Array[Vector4] = []
var _storm_day := -2147483648
var _cell_layout: Array[Vector4] = []   # (x, z) within the tile, radius, top
var _fill := 0.0

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
	_update_cells(cam.global_position if cam else Vector3.ZERO)


## Which day's thunderheads to show (the layout comes from the world seed).
func set_storm_day(day: int) -> void:
	if day == _storm_day:
		return
	_storm_day = day
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("thunderheads:%d" % day)
	_cell_layout.clear()
	for i in rng.randi_range(9, 14):
		_cell_layout.append(Vector4(rng.randf() * CELL_TILE, rng.randf() * CELL_TILE,
				rng.randf_range(2200.0, 4200.0), rng.randf_range(9500.0, 13000.0)))


# Cells drift with the wind and wrap around the camera, nearest copy first.
func _update_cells(cam: Vector3) -> void:
	cells.clear()
	if _fill <= 0.0:
		_push_cells()
		return
	var drift := wind * (Time.get_ticks_msec() / 1000.0)
	for c in _cell_layout:
		var p := Vector2(c.x, c.y) + drift
		var rel := Vector2(fposmod(p.x - cam.x + CELL_TILE * 0.5, CELL_TILE) - CELL_TILE * 0.5,
				fposmod(p.y - cam.z + CELL_TILE * 0.5, CELL_TILE) - CELL_TILE * 0.5)
		cells.append(Vector4(cam.x + rel.x, cam.z + rel.y, c.z, c.w))
	_push_cells()


func _push_cells() -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	var data: Array[Vector4] = cells.duplicate()
	data.resize(MAX_CELLS)
	for i in range(cells.size(), MAX_CELLS):
		data[i] = Vector4.ZERO
	mat.set_shader_parameter("cell_count", mini(cells.size(), MAX_CELLS))
	mat.set_shader_parameter("cells", data)


## A random point inside a thunderhead's tower (for in-cloud lightning), or
## Vector3.INF if there are none. Prefers cells within max_dist of near.
func random_storm_point(rng: RandomNumberGenerator, near: Vector3, max_dist := 40000.0) -> Vector3:
	var pool: Array[Vector4] = []
	for cell in cells:
		if Vector2(cell.x - near.x, cell.y - near.z).length() < max_dist:
			pool.append(cell)
	if pool.is_empty():
		return Vector3.INF
	var c: Vector4 = pool[rng.randi() % pool.size()]
	var a := rng.randf() * TAU
	var r := rng.randf() * c.z * 0.6
	return Vector3(c.x + cos(a) * r, lerpf(altitude + 800.0, c.w * 0.6, rng.randf()), c.y + sin(a) * r)


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


## Weather: cumulus coverage, thunderhead mix (0 cumulus .. 1 cumulonimbus), greyness.
func set_weather(coverage: float, fill: float, grey: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("coverage", coverage)
		mat.set_shader_parameter("fill", fill)
		mat.set_shader_parameter("grey", grey)
	_fill = fill
	visible = coverage > 0.001 or fill > 0.001


## Lightning: light the clouds around a point (amount 0 = no flash).
func set_flash(at: Vector3, amount: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("flash_pos", at)
		mat.set_shader_parameter("flash", amount)
