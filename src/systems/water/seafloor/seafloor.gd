class_name Seafloor
extends Node3D
## Procedural ocean floor: a heightfield from the world seed (broad basins and
## rises, ridges, and fine ripples), meshed and given collision in a square
## patch around the focus that is rebuilt as it moves. Seafloor.height_at()
## answers anywhere, so other systems (depth readouts, sampling, spawning) can
## ask for the bottom without the mesh.
##
## Patches are generated on a worker thread and swapped in when ready, so
## swimming never waits for terrain: a new patch is started once the focus is
## REBUILD_DISTANCE from the current centre, far inside the patch's edge.

const SIZE := 192                  ## Cells per side of the patch.
const CELL := 4.0                  ## m per cell: the patch is ~768 m across.
const REBUILD_DISTANCE := 120.0    ## Start the next patch this far from the current centre (edge is 384 m out).

@export var focus: Node3D
@export var material: Material

static var _noise_broad: FastNoiseLite
static var _noise_ridge: FastNoiseLite
static var _noise_fine: FastNoiseLite
static var _seed := -1

var _mesh := MeshInstance3D.new()
var _body := StaticBody3D.new()
var _shape := CollisionShape3D.new()
var _centre := Vector2(INF, INF)
var _task := -1                    # WorkerThreadPool task building the next patch
var _pending_centre := Vector2.ZERO
var _result := {}                  # filled by the worker


## Height of the sea floor (m, negative = below sea level) at world (x, z).
static func height_at(x: float, z: float) -> float:
	_ensure_noise()
	var broad := _noise_broad.get_noise_2d(x, z)           # basins and rises
	var ridge := 1.0 - absf(_noise_ridge.get_noise_2d(x, z))  # sharp-crested ridges
	var fine := _noise_fine.get_noise_2d(x, z)             # sand ripples and rubble
	return -(38.0 + 22.0 * broad - 9.0 * ridge * ridge + 0.6 * fine)


static func _ensure_noise() -> void:
	var s := WorldConfig.current().seed_for("seafloor")
	if s == _seed:
		return
	_seed = s
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
	_body.collision_layer = 1   # world
	_body.collision_mask = 0
	_body.add_child(_shape)
	add_child(_body)
	# the first patch is built right away, so there is a floor from the start
	var at := Vector2.ZERO if focus == null else Vector2(focus.global_position.x, focus.global_position.z)
	_pending_centre = (at / CELL).round() * CELL
	_generate()
	_apply()


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
	if p.distance_to(_centre) > REBUILD_DISTANCE:
		# snap to whole cells so the floor never swims as the patch moves
		_pending_centre = (p / CELL).round() * CELL
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
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	verts.resize(n * n)
	normals.resize(n * n)
	colours.resize(n * n)
	for j in n:
		for i in n:
			var h := heights[j * n + i]
			verts[j * n + i] = Vector3(-half + i * CELL, h, -half + j * CELL)
			var hl := heights[j * n + maxi(i - 1, 0)]
			var hr := heights[j * n + mini(i + 1, SIZE)]
			var hd := heights[maxi(j - 1, 0) * n + i]
			var hu := heights[mini(j + 1, SIZE) * n + i]
			var nrm := Vector3(hl - hr, 2.0 * CELL, hd - hu).normalized()
			normals[j * n + i] = nrm
			# sand on the flats, darker rock on slopes, paler on the rises
			var rock := smoothstep(0.85, 0.65, nrm.y)
			var sand := Color(0.62, 0.56, 0.42).lerp(Color(0.72, 0.67, 0.52), clampf((h + 40.0) / 25.0, 0.0, 1.0))
			colours[j * n + i] = sand.lerp(Color(0.3, 0.3, 0.28), rock)
	var idx := PackedInt32Array()
	idx.resize(SIZE * SIZE * 6)
	var k := 0
	for j in SIZE:
		for i in SIZE:
			var a := j * n + i
			idx[k] = a; idx[k + 1] = a + 1; idx[k + 2] = a + n
			idx[k + 3] = a + 1; idx[k + 4] = a + n + 1; idx[k + 5] = a + n
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = idx
	_result = {"centre": c, "arrays": arrays, "heights": heights}


# Main thread: swap the finished patch in.
func _apply() -> void:
	var c: Vector2 = _result.centre
	var n := SIZE + 1
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _result.arrays)
	_mesh.mesh = mesh
	_mesh.position = Vector3(c.x, 0.0, c.y)
	var hm := HeightMapShape3D.new()
	hm.map_width = n
	hm.map_depth = n
	hm.map_data = _result.heights
	_shape.shape = hm
	_shape.scale = Vector3(CELL, 1.0, CELL)
	_body.position = Vector3(c.x, 0.0, c.y)
	_centre = c
