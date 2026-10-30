class_name Terrain
extends Node3D
## The ground: every ground question goes through Terrain's static queries
## (height_at, surface_at, normal_at, ground_at), which ask the TerrainSource
## in use (Terrain.use()): for the generated world a HeightmapSource over its
## WorldData (WorldLoader sets it); a test, a streamed world or a second world
## only needs another source. With none, there is no ground (NO_GROUND).
##
## The node draws and collides the generated world's land and seafloor.
## Drawing: a quadtree picks patches of a single 16 x 16 grid mesh, finer near
## the camera (CDLOD); terrain.gdshader places them on the height map.
## Physics: a heightfield collider at the height map's own 2.5 m spacing
## follows the player, so you walk on exactly the drawn ground.

const GRID := 16                    ## Quads per patch side.
## LOD k: vertices 2.5 m * 2^k apart, up to the LOD whose one patch covers the world.
const MAX_PATCHES := 4000
const COLLIDER_SIZE := 161          ## Samples per side of the collider (400 m).

const NO_GROUND := -INF            ## height_at() with no ground in use.

static var _current: Terrain
static var _source: TerrainSource

@export var focus: Node3D           ## The collider follows this (the player).

var world: WorldData
var lods := 1

var _multimesh: MultiMesh
var _mesh_instance: MultiMeshInstance3D
var _material: ShaderMaterial
var _body: StaticBody3D
var _shape: HeightMapShape3D
var _patch_origin := Vector2(INF, INF)   ## World xz of the collider's sample (0, 0).
var _patch_heights := PackedFloat32Array()


static func current() -> Terrain:
	return _current


## How many LODs cover a world: the coarsest has one patch over all of it.
static func lods_for(w: WorldData) -> int:
	return ceili(log(w.size / (GRID * w.spacing)) / log(2.0)) + 1


## Answer ground questions from `source` from now on (null: no ground).
static func use(source: TerrainSource) -> void:
	_source = source


static func source() -> TerrainSource:
	return _source


static func has_ground() -> bool:
	return _source != null


## Ground height (m) at a world point, smooth (NO_GROUND without a source).
static func height_at(x: float, z: float) -> float:
	return _source.height_at(x, z) if _source else NO_GROUND


## Ground height (m) exactly as the ground is drawn and collides, for things
## that must lie on what you see (water down a waterfall's face).
static func surface_at(x: float, z: float) -> float:
	return _source.surface_at(x, z) if _source else NO_GROUND


static func normal_at(x: float, z: float) -> Vector3:
	return _source.normal_at(x, z) if _source else Vector3.UP


## What the ground is: rock, sand, forest density, ambient occlusion (0..1).
static func ground_at(x: float, z: float) -> Color:
	return _source.ground_at(x, z) if _source else Color(0.0, 0.0, 0.0, 1.0)


func _enter_tree() -> void:
	_current = self


func _exit_tree() -> void:
	if _current == self:
		_current = null


func _ready() -> void:
	world = WorldData.get_world()
	if world == null:
		return
	lods = lods_for(world)
	_body = StaticBody3D.new()
	_body.name = "Collider"
	var cs := CollisionShape3D.new()
	_shape = HeightMapShape3D.new()
	cs.shape = _shape
	_body.add_child(cs)
	add_child(_body)
	_build_drawing()
	if focus:
		prepare_at(focus.global_position)


func _process(_delta: float) -> void:
	if world == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		_select_patches(Vector2(cam.global_position.x, cam.global_position.z))


func _physics_process(_delta: float) -> void:
	if world and focus:
		var p := Vector2(focus.global_position.x, focus.global_position.z)
		var centre := _patch_origin + Vector2.ONE * world.spacing * (COLLIDER_SIZE - 1) * 0.5
		if p.distance_to(centre) > 100.0:
			prepare_at(focus.global_position)


# --- drawing ------------------------------------------------------------------------

## The height map as two mipmapped R8 textures (high and low bytes), for any
## shader that needs the ground.
func height_textures() -> Array:
	return [_material.get_shader_parameter("height_hi"), _material.get_shader_parameter("height_lo")]


## The ground masks texture (rock, sand, forest, ambient occlusion), for any
## shader that colours things as the ground is coloured.
func ground_texture() -> Texture2D:
	return _material.get_shader_parameter("ground")


func _build_drawing() -> void:
	var tex := HeightmapSource.new(world).height_textures()
	_material = ShaderMaterial.new()
	_material.shader = preload("res://src/systems/terrain/terrain.gdshader")
	_material.set_shader_parameter("height_hi", tex[0])
	_material.set_shader_parameter("height_lo", tex[1])
	_material.set_shader_parameter("ground", ImageTexture.create_from_image(world.ground))
	_material.set_shader_parameter("river_mask", world.river_network.mask_texture(world.texels / 4))
	_material.set_shader_parameter("world_size", world.size)
	_material.set_shader_parameter("texels", world.texels)
	_material.set_shader_parameter("h_min", world.h_min)
	_material.set_shader_parameter("h_scale", world.h_scale)
	_material.set_shader_parameter("top_lod", lods - 1)
	_material.set_shader_parameter("grid_dim", float(GRID))
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	_multimesh.mesh = _patch_mesh()
	_multimesh.instance_count = MAX_PATCHES
	_multimesh.visible_instance_count = 0
	_mesh_instance = MultiMeshInstance3D.new()
	_mesh_instance.name = "Patches"
	_mesh_instance.multimesh = _multimesh
	_mesh_instance.material_override = _material
	_mesh_instance.custom_aabb = AABB(Vector3(-world.size, -400.0, -world.size), Vector3(world.size * 2.0, 1600.0, world.size * 2.0))
	_mesh_instance.top_level = true
	add_child(_mesh_instance)


func _patch_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	for j in GRID + 1:
		for i in GRID + 1:
			verts.append(Vector3(float(i) / GRID, 0.0, float(j) / GRID))
	var idx := PackedInt32Array()
	for j in GRID:
		for i in GRID:
			var a := j * (GRID + 1) + i
			# alternate the diagonal quad by quad: with every quad split the same
			# way, smooth shapes pick up a sawtooth along that diagonal
			if (i + j) % 2 == 0:
				idx.append_array([a, a + 1, a + GRID + 1, a + 1, a + GRID + 2, a + GRID + 1])
			else:
				idx.append_array([a, a + 1, a + GRID + 2, a, a + GRID + 2, a + GRID + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _spacing(k: int) -> float:
	return world.spacing * float(1 << k)


# LOD k patches reach this far. Four patch widths: then the farthest LOD k - 1
# patch ends (range(k-1) plus a patch diagonal, 0.85 of this) before LOD k
# starts morphing toward k + 1 (at 0.87), which keeps seams closed.
func _range(k: int) -> float:
	return 4.0 * GRID * _spacing(k)


var _patches: Array[Vector4] = []   # origin x, origin z, lod, size


func _select_patches(cam: Vector2) -> void:
	_patches.clear()
	var half := world.size * 0.5
	_visit(Vector2(-half, -half), lods - 1, cam)
	var count := mini(_patches.size(), MAX_PATCHES)
	for i in count:
		var p := _patches[i]
		var k := int(p.z)
		_multimesh.set_instance_transform(i, Transform3D(Basis(), Vector3(p.x, 0.0, p.y)))
		var r := _range(k)
		_multimesh.set_instance_custom_data(i, Color(k, r * 0.87, r * 0.98, p.w))
	_multimesh.visible_instance_count = count


func _visit(origin: Vector2, k: int, cam: Vector2) -> void:
	var size := GRID * _spacing(k)
	if k > 0 and _box_distance(origin, size, cam) < _range(k - 1):
		var half := size * 0.5
		for c: Vector2 in [Vector2.ZERO, Vector2(half, 0.0), Vector2(0.0, half), Vector2(half, half)]:
			_visit(origin + c, k - 1, cam)
	else:
		_patches.append(Vector4(origin.x, origin.y, k, size))


static func _box_distance(origin: Vector2, size: float, p: Vector2) -> float:
	var dx := maxf(0.0, maxf(origin.x - p.x, p.x - origin.x - size))
	var dz := maxf(0.0, maxf(origin.y - p.y, p.y - origin.y - size))
	return sqrt(dx * dx + dz * dz)


# --- collider ---------------------------------------------------------------------------

## Build the collider around a point now (before putting someone there).
func prepare_at(p: Vector3) -> void:
	if world == null:
		return
	var s := world.spacing
	var half := world.size * 0.5
	var ix := roundi((p.x + half) / s) - (COLLIDER_SIZE - 1) / 2
	var iz := roundi((p.z + half) / s) - (COLLIDER_SIZE - 1) / 2
	var heights := _source.height_grid(ix, iz, COLLIDER_SIZE) if _source else PackedFloat32Array()
	_shape.map_width = COLLIDER_SIZE
	_shape.map_depth = COLLIDER_SIZE
	_shape.map_data = heights
	_patch_heights = heights
	_patch_origin = Vector2(ix * s - half, iz * s - half)
	var cs: CollisionShape3D = _body.get_child(0)
	cs.scale = Vector3(s, 1.0, s)
	cs.global_position = Vector3(_patch_origin.x + s * (COLLIDER_SIZE - 1) * 0.5, 0.0, _patch_origin.y + s * (COLLIDER_SIZE - 1) * 0.5)


## True when the collider covers (x, z) with a margin.
func collider_covers(x: float, z: float) -> bool:
	var gx := (x - _patch_origin.x) / world.spacing
	var gz := (z - _patch_origin.y) / world.spacing
	return gx > 4.0 and gz > 4.0 and gx < COLLIDER_SIZE - 5 and gz < COLLIDER_SIZE - 5
