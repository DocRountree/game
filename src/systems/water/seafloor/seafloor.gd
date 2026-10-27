class_name Seafloor
extends Node3D
## Procedural ocean floor: a heightfield from the world seed (broad basins and
## rises, ridges, and fine ripples) with collision in a square patch around the
## focus that is rebuilt as it moves. It is drawn by seafloor.gdshader on a
## camera-centred grid that adds fine fractal relief and endless shading detail. Seafloor.height_at()
## answers anywhere, so other systems (depth readouts, sampling, spawning) can
## ask for the bottom without the mesh.
##
## Patches are generated on a worker thread and swapped in when ready, so
## swimming never waits for terrain: a new patch is started once the focus is
## REBUILD_DISTANCE from the current centre, far inside the patch's edge.

const SIZE := 192                  ## Cells per side of the patch.
const CELL := 4.0                  ## m per cell: the patch is ~768 m across.
const REBUILD_DISTANCE := 120.0    ## Start the next patch this far from the current centre (edge is 384 m out).
const FAR_SIZE := 256              ## Cells per side of the coarse far field (for distant islands).
const FAR_CELL := 64.0             ## m per cell: ~16 km across.
const FAR_REBUILD := 3000.0

@export var focus: Node3D
@export var material: ShaderMaterial   ## seafloor.gdshader

static var _noise_broad: FastNoiseLite
static var _noise_ridge: FastNoiseLite
static var _noise_fine: FastNoiseLite
static var _seed := -1

var _mesh := OceanSurface.new()      # camera-centred polar grid
var _body := StaticBody3D.new()
var _shape := CollisionShape3D.new()
var _centre := Vector2(INF, INF)
var _task := -1                    # WorkerThreadPool task building the next patch
var _pending_centre := Vector2.ZERO
var _result := {}                  # filled by the worker
var _far_centre := Vector2(INF, INF)


## Height of the sea floor (m, negative = below sea level) at world (x, z).
## Height of the ground (m; negative = under the sea) at world (x, z): the sea
## floor, rising into islands where the archipelago puts them.
static func height_at(x: float, z: float) -> float:
	_ensure_noise()
	var broad := _noise_broad.get_noise_2d(x, z)           # basins and rises
	var ridge := 1.0 - absf(_noise_ridge.get_noise_2d(x, z))  # sharp-crested ridges
	var fine := _noise_fine.get_noise_2d(x, z)             # rubble
	var floor_h := -(38.0 + 22.0 * broad - 9.0 * ridge * ridge + 0.6 * fine)
	return maxf(floor_h, _islands(x, z, floor_h, ridge))


const ISLAND_CELL := 3000.0   ## m: at most one island per cell of this grid.
const ISLAND_CHANCE := 0.5
const SPAWN_CLEAR := 450.0    ## m of open water kept around the world origin.


# The archipelago: islands placed on a coarse grid from the world seed. Each is a
# warped dome with ridged slopes and a shallow shelf around it.
static func _islands(x: float, z: float, floor_h: float, ridge: float) -> float:
	var best := -1e9
	var cx := floori(x / ISLAND_CELL)
	var cz := floori(z / ISLAND_CELL)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var isl := _island(cx + dx, cz + dz)
			if isl.is_empty():
				continue
			var r: float = isl.radius
			var d := Vector2(x - isl.x, z - isl.z).length()
			if d > r * 2.0:
				continue
			# warp the distance so coastlines wander
			d += _noise_ridge.get_noise_2d(x * 1.7 + 311.0, z * 1.7) * r * 0.3
			var q := d / r
			var dome: float = isl.peak * pow(maxf(1.0 - q * q, 0.0), 1.4) - 6.0 * q
			dome += isl.peak * 0.18 * ridge * ridge * maxf(1.0 - q, 0.0)   # ridges and gullies on the slopes
			var shelf := lerpf(-4.0, floor_h, smoothstep(0.9, 1.9, q))  # shallows around it
			best = maxf(best, maxf(dome, shelf))
	return best


static var _island_cache := {}


static func _island(cx: int, cz: int) -> Dictionary:
	var key := Vector2i(cx, cz)
	if _island_cache.has(key):
		return _island_cache[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(_seed) + ":island:" + str(key))
	var isl := {}
	if rng.randf() < ISLAND_CHANCE:
		var r := rng.randf_range(150.0, 700.0)
		var pos := Vector2((cx + rng.randf_range(0.25, 0.75)) * ISLAND_CELL, (cz + rng.randf_range(0.25, 0.75)) * ISLAND_CELL)
		if pos.length() - r * 2.0 > SPAWN_CLEAR:
			isl = {"x": pos.x, "z": pos.y, "radius": r, "peak": rng.randf_range(20.0, 120.0) * clampf(r / 400.0, 0.5, 1.2)}
	_island_cache[key] = isl
	return isl


static func _ensure_noise() -> void:
	# the world seed lives in the scene tree, which only the main thread may touch;
	# worker threads use the noise the main thread set up before starting them
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return
	var s := WorldConfig.current().seed_for("seafloor")
	if s == _seed:
		return
	_seed = s
	_island_cache.clear()
	_noise_broad = FastNoiseLite.new()
	_noise_broad.seed = s
	_noise_broad.frequency = 1.0 / 900.0
	_noise_broad.fractal_octaves = 4
	_noise_ridge = FastNoiseLite.new()
	_noise_ridge.seed = s + 1
	_noise_ridge.frequency = 1.0 / 260.0
	_noise_ridge.fractal_octaves = 3
	_noise_fine = FastNoiseLite.new()
	_noise_fine.seed = s + 2
	_noise_fine.frequency = 1.0 / 9.0
	_noise_fine.fractal_octaves = 2


func _ready() -> void:
	_mesh.material_override = material
	add_child(_mesh)
	# ~30 cm spacing out to ~17 m (sand ripples are real geometry there), ~7 m at
	# the far edge ~600 m out; ~185k vertices
	_mesh.rings = 640   # out to ~15 km, so distant islands show
	_mesh.segments = 512
	_mesh.inner_spacing = 0.1
	_mesh.growth = 0.012
	_mesh.mesh = _mesh.build_mesh()
	_mesh.custom_aabb = AABB(Vector3(-16000, -200, -16000), Vector3(32000, 400, 32000))
	_body.collision_layer = 1   # world
	_body.collision_mask = 0
	_body.add_child(_shape)
	add_child(_body)
	# the first patch is built right away, so there is a floor from the start
	var at := Vector2.ZERO if focus == null else Vector2(focus.global_position.x, focus.global_position.z)
	_pending_centre = (at / CELL).round() * CELL
	_generate()
	_apply()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam:
		_mesh.global_position = Vector3(cam.global_position.x, 0.0, cam.global_position.z)


func _physics_process(_delta: float) -> void:
	if focus == null:
		return
	if _task >= 0:
		if WorkerThreadPool.is_task_completed(_task):
			WorkerThreadPool.wait_for_task_completion(_task)
			_task = -1
			_apply()
		return
	var p := Vector2(focus.global_position.x, focus.global_position.z)
	if p.distance_to(_centre) > REBUILD_DISTANCE or p.distance_to(_far_centre) > FAR_REBUILD:
		# snap to whole cells so the floor never swims as the patch moves
		_pending_centre = (p / CELL).round() * CELL
		_ensure_noise()
		_task = WorkerThreadPool.add_task(_generate)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


# Worker thread: heights and mesh arrays only (no scene or server calls).
func _generate() -> void:
	var c := _pending_centre
	var n := SIZE + 1
	var half := SIZE * CELL * 0.5
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	for j in n:
		for i in n:
			heights[j * n + i] = height_at(c.x - half + i * CELL, c.y - half + j * CELL)
	_result = {"centre": c, "heights": heights}
	# the coarse far field, only when the focus has moved far enough
	var fc := (c / FAR_CELL).round() * FAR_CELL
	if fc.distance_to(_far_centre) > FAR_REBUILD:
		var fn := FAR_SIZE + 1
		var fhalf := FAR_SIZE * FAR_CELL * 0.5
		var far := PackedFloat32Array()
		far.resize(fn * fn)
		for j in fn:
			for i in fn:
				far[j * fn + i] = height_at(fc.x - fhalf + i * FAR_CELL, fc.y - fhalf + j * FAR_CELL)
		_result.far_centre = fc
		_result.far = far


# Main thread: swap the finished patch in.
func _apply() -> void:
	var c: Vector2 = _result.centre
	var n := SIZE + 1
	var half := SIZE * CELL * 0.5
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, (_result.heights as PackedFloat32Array).to_byte_array())
	if material:
		material.set_shader_parameter("heights", ImageTexture.create_from_image(img))
		# texel centres sit on the grid points: the rect spans half a cell beyond them
		material.set_shader_parameter("patch_rect", Vector3(c.x - half - CELL * 0.5, c.y - half - CELL * 0.5, n * CELL))
	if _result.has("far") and material:
		var fn := FAR_SIZE + 1
		var fc: Vector2 = _result.far_centre
		var fhalf := FAR_SIZE * FAR_CELL * 0.5
		var fimg := Image.create_from_data(fn, fn, false, Image.FORMAT_RF, (_result.far as PackedFloat32Array).to_byte_array())
		material.set_shader_parameter("far_heights", ImageTexture.create_from_image(fimg))
		material.set_shader_parameter("far_rect", Vector3(fc.x - fhalf - FAR_CELL * 0.5, fc.y - fhalf - FAR_CELL * 0.5, fn * FAR_CELL))
		_far_centre = fc
	var hm := HeightMapShape3D.new()
	hm.map_width = n
	hm.map_depth = n
	hm.map_data = _result.heights
	_shape.shape = hm
	_shape.scale = Vector3(CELL, 1.0, CELL)
	_body.position = Vector3(c.x, 0.0, c.y)
	_centre = c
