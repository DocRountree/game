class_name Terrain
extends Node3D
## The land and the seafloor. On start it loads this world's baked maps from
## the cache, or bakes them (WorldBake) on a worker thread the first time.
##
## Drawing: a compute shader (terrain_levels.glsl) keeps nested height levels
## centred on the camera, from the baked maps plus fractal detail, gullies and
## river channels. A quadtree picks patches of a single 16 x 16 grid mesh, finer
## near the camera (CDLOD); terrain.gdshader places them on the levels.
##
## Physics: a heightfield collider follows the player, read back from level 1
## (1 m spacing), so you walk on exactly the drawn ground. Without a GPU (tests)
## it is built from the baked maps.
##
## Gameplay asks Terrain.height_at(x, z) and Terrain.maps().

signal maps_ready

const LEVELS := 11                  ## Level k: 256 texels spaced S0 * 2^k (0.5 m .. 512 m).
const LEVEL_SIZE := 256
const S0 := 0.5
const GRID := 16                    ## Quads per patch side.
const MAX_PATCHES := 5000
const VIEW_RADIUS := 30000.0        ## Draw terrain out to here (m): the whole world, to the horizon.
const DEEP := -4000.0               ## Height reported before the world exists.

## Grid cells per side for the bake (fixed per world version; tests use fewer).
static var bake_resolution := 1600
static var world_size := 30000.0
static var _current: Terrain

@export var focus: Node3D           ## The collider follows this (the player).
@export var detail := 1.0           ## Strength of the fine detail.

var _maps: WorldMaps
var _bake: WorldBake
var _task := -1
var progress := 0.0                 ## Bake progress 0..1 while generating.

# GPU
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _buffers: Array[RID] = []
var _biome_buffer: RID
var _levels_tex: RID
var _set: RID
var _gpu_ok := false
var _level_origin: Array[Vector2] = []
var _levels_rd: Texture2DArrayRD
var _water_tex: RID
var _water_rd: Texture2DArrayRD
var _river_material: ShaderMaterial
var _river_instance: MultiMeshInstance3D

# drawing
var _multimesh: MultiMesh
var _mesh_instance: MultiMeshInstance3D
var _material: ShaderMaterial

# physics
var _body: StaticBody3D
var _shape: HeightMapShape3D
var _patch_origin := Vector2(INF, INF)  ## World xz of the collider's texel (0, 0).
var _patch_spacing := 1.0
var _patch_size := 0
var _patch_heights := PackedFloat32Array()
var _readback_pending := false
var _detail_seed := 0


static func current() -> Terrain:
	return _current


## The baked world, or null while it is still generating.
static func maps() -> WorldMaps:
	return _current._maps if _current else null


## Ground height (m) at a world point: the collider's detailed heights near
## the player, the baked map elsewhere, DEEP before the world exists.
static func height_at(x: float, z: float) -> float:
	if _current == null or _current._maps == null:
		return DEEP
	return _current._height(x, z)


static func cache_path(config: WorldConfig, cells: int) -> String:
	return "user://worlds/%d_v%d_%d.wmap" % [config.world_seed, WorldBake.VERSION, cells]


func _enter_tree() -> void:
	_current = self


func _exit_tree() -> void:
	if _current == self:
		_current = null
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _ready() -> void:
	_body = StaticBody3D.new()
	_body.name = "Collider"
	var cs := CollisionShape3D.new()
	_shape = HeightMapShape3D.new()
	cs.shape = _shape
	_body.add_child(cs)
	add_child(_body)
	var config := WorldConfig.current()
	_task = WorkerThreadPool.add_task(_load_or_bake.bind(config, bake_resolution, world_size), true, "world bake")


## Bake (or load) right now, on this thread. For tests and tools.
func generate_now() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _maps == null:
		_load_or_bake(WorldConfig.current(), bake_resolution, world_size)
	_on_maps()


func _load_or_bake(config: WorldConfig, cells: int, side: float) -> void:
	var path := cache_path(config, cells)
	var loaded := WorldMaps.load_from(path, WorldBake.VERSION)
	if loaded and loaded.seed == config.world_seed and is_equal_approx(loaded.size, side):
		loaded.network()   # index the rivers here, off the main thread
		_maps = loaded
		return
	_bake = WorldBake.new(config, cells, side)
	var baked := _bake.run()
	baked.save(path)
	baked.network()
	_maps = baked


func _process(_delta: float) -> void:
	if _task >= 0:
		progress = _bake.progress if _bake else 0.0
		if WorkerThreadPool.is_task_completed(_task):
			WorkerThreadPool.wait_for_task_completion(_task)
			_task = -1
			_on_maps()
		return
	if _maps == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		var c := Vector2(cam.global_position.x, cam.global_position.z)
		if _gpu_ok:
			_update_levels(c)
			_select_patches(c)
			_material.set_shader_parameter("view_pos", cam.global_position)
			_river_material.set_shader_parameter("view_pos", cam.global_position)
	_update_collider()


func _on_maps() -> void:
	if _maps == null or _material != null:
		return
	progress = 1.0
	_detail_seed = WorldConfig.current().seed_for("terrain-detail") & 0x7fffffff
	_build_drawing()
	_rd = RenderingServer.get_rendering_device()
	if _rd:
		RenderingServer.call_on_render_thread(_create_gpu)
	_spawn_water()
	maps_ready.emit()


# Lakes (those holding water today) and the rivers become water bodies.
func _spawn_water() -> void:
	var ocean: Ocean = null
	for b in WaterBody.all():
		if b is Ocean:
			ocean = b
	for i in _maps.lakes.size():
		var lake: Dictionary = _maps.lakes[i]
		if lake.dry:
			continue
		var body := LakeBody.new()
		body.setup(lake, i)
		add_child(body)
	var rivers := RiverBody.new()
	rivers.material = _river_material
	rivers.ocean = ocean
	if ocean:
		rivers.set_sun(ocean.sun)
	add_child(rivers)


# --- height queries -------------------------------------------------------------

func _height(x: float, z: float) -> float:
	if _patch_size > 0:
		var gx := (x - _patch_origin.x) / _patch_spacing
		var gz := (z - _patch_origin.y) / _patch_spacing
		if gx >= 0.0 and gz >= 0.0 and gx < _patch_size - 1 and gz < _patch_size - 1:
			var ix := int(gx)
			var iz := int(gz)
			var fx := gx - ix
			var fz := gz - iz
			var i := iz * _patch_size + ix
			var a := lerpf(_patch_heights[i], _patch_heights[i + 1], fx)
			var b := lerpf(_patch_heights[i + _patch_size], _patch_heights[i + _patch_size + 1], fx)
			return lerpf(a, b, fz)
	return _maps.height_at(x, z)


var _seabed: ImageTexture


## Terrain height over the world grid as a float texture (for the water shaders).
func seabed_texture() -> ImageTexture:
	if _seabed == null and _maps:
		var img := Image.create_from_data(_maps.n, _maps.n, false, Image.FORMAT_RF, _maps.height.to_byte_array())
		_seabed = ImageTexture.create_from_image(img)
	return _seabed


# --- drawing ------------------------------------------------------------------------

func _build_drawing() -> void:
	_material = ShaderMaterial.new()
	_material.shader = preload("res://src/systems/terrain/terrain.gdshader")
	_material.set_shader_parameter("ground", _ground_texture())
	_material.set_shader_parameter("biome_tint", _biome_tint_texture())
	_material.set_shader_parameter("world_size", _maps.size)
	_material.set_shader_parameter("world_center", _maps.center)
	_material.set_shader_parameter("top_level", LEVELS - 1)
	_material.set_shader_parameter("grid_dim", float(GRID))
	_material.set_shader_parameter("level_size", float(LEVEL_SIZE))
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
	_mesh_instance.custom_aabb = AABB(Vector3(-1e6, -6000.0, -1e6), Vector3(2e6, 12000.0, 2e6))
	_mesh_instance.top_level = true
	add_child(_mesh_instance)
	_level_origin.resize(LEVELS)
	_level_origin.fill(Vector2(INF, INF))
	# river water: the same patches again, with the river shader
	_river_material = ShaderMaterial.new()
	_river_material.shader = preload("res://src/systems/water/river/river.gdshader")
	_river_material.set_shader_parameter("top_level", LEVELS - 1)
	_river_material.set_shader_parameter("grid_dim", float(GRID))
	_river_material.set_shader_parameter("level_size", float(LEVEL_SIZE))
	_river_instance = MultiMeshInstance3D.new()
	_river_instance.name = "RiverWater"
	_river_instance.multimesh = _multimesh
	_river_instance.material_override = _river_material
	_river_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_river_instance.custom_aabb = _mesh_instance.custom_aabb
	_river_instance.top_level = true
	add_child(_river_instance)


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


# Per cell, two RGBA8 words of biome weights for the compute shader: land
# (mesa, prairie, forest, own-biome landmass) and seafloor (coral reef, root
# maze, kelp forest, -), softened over a few cells so biomes blend.
func _biome_weights() -> PackedByteArray:
	var n := _maps.n
	var land := PackedByteArray()
	land.resize(n * n * 4)
	var sea := PackedByteArray()
	sea.resize(n * n * 4)
	var slot := {WorldMaps.Biome.MESA: 0, WorldMaps.Biome.PRAIRIE: 1, WorldMaps.Biome.FOREST: 2,
			WorldMaps.Biome.ARCHIPELAGO: 3, WorldMaps.Biome.VOLCANIC: 3, WorldMaps.Biome.ISLAND: 3,
			WorldMaps.Biome.CORAL_REEF: 4, WorldMaps.Biome.ROOT_MAZE: 5, WorldMaps.Biome.KELP_FOREST: 6}
	for i in n * n:
		var b := _maps.biome[i]
		if slot.has(b):
			var k: int = slot[b]
			if k < 4:
				land[i * 4 + k] = 255
			else:
				sea[i * 4 + k - 4] = 255
	var a := _soften(land, n)
	var c := _soften(sea, n)
	var data := PackedByteArray()
	data.resize(n * n * 8)
	for i in n * n:
		for k in 4:
			data[i * 8 + k] = a[i * 4 + k]
			data[i * 8 + 4 + k] = c[i * 4 + k]
	return data


# An RGBA8 map blurred over about four cells (down a quarter and back up,
# natively): biome edges fade over ~80 m instead of stepping cell by cell.
static func _soften(rgba: PackedByteArray, n: int) -> PackedByteArray:
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, rgba)
	img.resize(n / 4, n / 4, Image.INTERPOLATE_BILINEAR)
	img.resize(n, n, Image.INTERPOLATE_CUBIC)
	return img.get_data()


# The biomes' marker colours over the world (alpha: how marked), for the
# terrain shader.
func _biome_tint_texture() -> ImageTexture:
	var n := _maps.n
	var data := PackedByteArray()
	data.resize(n * n * 4)
	for i in n * n:
		var c: Color = WorldMaps.BIOME_TINT[_maps.biome[i]]
		data[i * 4] = int(c.r * 255.0)
		data[i * 4 + 1] = int(c.g * 255.0)
		data[i * 4 + 2] = int(c.b * 255.0)
		data[i * 4 + 3] = int(c.a * 255.0)
	return ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, _soften(data, n)))


func _ground_texture() -> ImageTexture:
	var n := _maps.n
	var data := PackedByteArray()
	data.resize(n * n * 4)
	for i in n * n:
		data[i * 4 + mini(_maps.material[i], 3)] = 255
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)


static func _spacing(k: int) -> float:
	return S0 * float(1 << k)


# LOD k patches reach this far. Four patch widths: then the farthest LOD k - 1
# patch ends (range(k-1) plus a patch diagonal, 0.85 of this) before LOD k
# starts morphing toward k + 1 (at 0.87), which is what keeps seams closed.
static func _range(k: int) -> float:
	return 4.0 * GRID * _spacing(k)


var _patches: Array[Vector4] = []   # origin x, origin z, lod, size


func _select_patches(cam: Vector2) -> void:
	_patches.clear()
	var root := GRID * _spacing(LEVELS - 1)
	var reach := ceili(VIEW_RADIUS / root)
	var rx := floori(cam.x / root)
	var rz := floori(cam.y / root)
	for z in range(rz - reach, rz + reach + 1):
		for x in range(rx - reach, rx + reach + 1):
			var o := Vector2(x * root, z * root)
			if _box_distance(o, root, cam) < VIEW_RADIUS:
				_visit(o, LEVELS - 1, cam)
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


# --- GPU levels -----------------------------------------------------------------------

const MIPS := 6   ## Must match terrain_levels.glsl.


# The baked heights and 2x2-averaged copies, finest first, in one array.
func _height_mips() -> PackedFloat32Array:
	var out := _maps.height.duplicate()
	var src := _maps.height
	var size := _maps.n
	for _m in range(1, MIPS):
		var half := size / 2
		var dst := PackedFloat32Array()
		dst.resize(half * half)
		for y in half:
			for x in half:
				var i := 2 * y * size + 2 * x
				dst[y * half + x] = (src[i] + src[i + 1] + src[i + size] + src[i + size + 1]) * 0.25
		out.append_array(dst)
		src = dst
		size = half
	return out

func _create_gpu() -> void:
	var shader_file: RDShaderFile = load("res://src/systems/terrain/terrain_levels.glsl")
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("Terrain: " + spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var n := _maps.n
	var ground := PackedByteArray()
	ground.resize(n * n * 4)
	for i in n * n:
		ground[i * 4 + mini(_maps.material[i], 3)] = 255
	var net := _maps.network()
	var segs := net.segments if net.segments.size() > 0 else PackedFloat32Array([0, 0, 1, 0, 0, 0, 1, 1, 0, 0, -1, -1, 0, 0, 0, 0])
	for data: PackedByteArray in [_height_mips().to_byte_array(), segs.to_byte_array(),
			net.tiles.to_byte_array(), ground, _maps.water_level.to_byte_array()]:
		_buffers.append(_rd.storage_buffer_create(data.size(), data))
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = LEVEL_SIZE
	fmt.height = LEVEL_SIZE
	fmt.array_layers = LEVELS
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_levels_tex = _rd.texture_create(fmt, RDTextureView.new())
	_water_tex = _rd.texture_create(fmt, RDTextureView.new())
	var uniforms: Array[RDUniform] = []
	for b in _buffers.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b
		u.add_id(_buffers[b])
		uniforms.append(u)
	var ui := RDUniform.new()
	ui.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	ui.binding = 5
	ui.add_id(_levels_tex)
	uniforms.append(ui)
	var uw := RDUniform.new()
	uw.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uw.binding = 6
	uw.add_id(_water_tex)
	uniforms.append(uw)
	var ub := RDUniform.new()
	ub.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ub.binding = 7
	var bio := _biome_weights()
	_biome_buffer = _rd.storage_buffer_create(bio.size(), bio)
	ub.add_id(_biome_buffer)
	uniforms.append(ub)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)
	_set_gpu_ready.call_deferred()


func _set_gpu_ready() -> void:
	_levels_rd = Texture2DArrayRD.new()
	_levels_rd.texture_rd_rid = _levels_tex
	_material.set_shader_parameter("levels", _levels_rd)
	_water_rd = Texture2DArrayRD.new()
	_water_rd.texture_rd_rid = _water_tex
	_river_material.set_shader_parameter("levels", _levels_rd)
	_river_material.set_shader_parameter("water_levels", _water_rd)
	_gpu_ok = true


func _update_levels(cam: Vector2) -> void:
	var changed: Array[int] = []
	var rects := PackedVector4Array()
	rects.resize(12)
	for k in LEVELS:
		var s := _spacing(k)
		var snap := 2.0 * s
		var o := Vector2(floorf(cam.x / snap) * snap, floorf(cam.y / snap) * snap) - Vector2.ONE * s * LEVEL_SIZE * 0.5
		if o != _level_origin[k]:
			_level_origin[k] = o
			changed.append(k)
		rects[k] = Vector4(o.x, o.y, s, 0.0)
	if changed.is_empty():
		return
	_material.set_shader_parameter("level_rects", rects)
	_river_material.set_shader_parameter("level_rects", rects)
	var origins := _level_origin.duplicate()
	var physics_layer := -1
	if changed.has(1) and _wants_collider() and not _readback_pending:
		physics_layer = 1
		_readback_pending = true
	RenderingServer.call_on_render_thread(_dispatch_levels.bind(changed, origins, physics_layer))


func _dispatch_levels(changed: Array[int], origins: Array[Vector2], physics_layer: int) -> void:
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _set, 0)
	for mode in 2:
		for k in changed:
			var pc := PackedByteArray()
			pc.resize(64)
			pc.encode_float(0, origins[k].x)
			pc.encode_float(4, origins[k].y)
			pc.encode_float(8, _spacing(k))
			pc.encode_float(12, _maps.size)
			pc.encode_s32(16, _maps.n)
			pc.encode_s32(20, k)
			pc.encode_s32(24, mode)
			pc.encode_s32(28, _detail_seed)
			pc.encode_float(32, _maps.cell)
			pc.encode_float(36, detail)
			pc.encode_float(40, _maps.center.x)
			pc.encode_float(44, _maps.center.y)
			pc.encode_s32(48, _maps.network().tiles_per_side)
			pc.encode_float(52, RiverNetwork.TILE)
			_rd.compute_list_set_push_constant(cl, pc, pc.size())
			_rd.compute_list_dispatch(cl, LEVEL_SIZE / 16, LEVEL_SIZE / 16, 1)
		_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	if physics_layer >= 0:
		_rd.texture_get_data_async(_levels_tex, physics_layer, _on_level_readback.bind(origins[physics_layer]))


# --- collider ---------------------------------------------------------------------------

var _wanted_center := Vector2(INF, INF)
var _gpu_patch: PackedByteArray
var _gpu_patch_origin := Vector2.ZERO
var _gpu_patch_new := false


# Rebuild the collider when the player has moved well away from its centre.
func _wants_collider() -> bool:
	if focus == null:
		return false
	var p := Vector2(focus.global_position.x, focus.global_position.z)
	return p.distance_to(_patch_origin + Vector2.ONE * _patch_spacing * _patch_size * 0.5) > 48.0 or _patch_size == 0


func _on_level_readback(data: PackedByteArray, origin: Vector2) -> void:
	_gpu_patch = data
	_gpu_patch_origin = origin
	_gpu_patch_new = true
	_readback_pending = false


func _update_collider() -> void:
	if focus == null:
		return
	if _gpu_ok:
		if _gpu_patch_new:
			_gpu_patch_new = false
			var f := _gpu_patch.to_float32_array()
			var heights := PackedFloat32Array()
			heights.resize(LEVEL_SIZE * LEVEL_SIZE)
			for i in heights.size():
				heights[i] = f[i * 4]
			_apply_collider(heights, LEVEL_SIZE, 1.0, _gpu_patch_origin)
		elif not _readback_pending and _wants_collider():
			_level_origin[1] = Vector2(INF, INF)   # recompute level 1 and read it back
		return
	if _rd == null and _wants_collider():
		# no GPU: build from the baked maps
		var size := 129
		var spacing := 1.0
		var c := Vector2(focus.global_position.x, focus.global_position.z)
		var o := (c / spacing).floor() * spacing - Vector2.ONE * spacing * (size - 1) * 0.5
		var heights := PackedFloat32Array()
		heights.resize(size * size)
		for z in size:
			for x in size:
				heights[z * size + x] = _maps.height_at(o.x + x * spacing, o.y + z * spacing)
		_apply_collider(heights, size, spacing, o)


func _apply_collider(heights: PackedFloat32Array, size: int, spacing: float, origin: Vector2) -> void:
	_shape.map_width = size
	_shape.map_depth = size
	_shape.map_data = heights
	_patch_heights = heights
	_patch_size = size
	_patch_spacing = spacing
	_patch_origin = origin
	var cs: CollisionShape3D = _body.get_child(0)
	cs.scale = Vector3(spacing, 1.0, spacing)
	cs.global_position = Vector3(origin.x + spacing * (size - 1) * 0.5, 0.0, origin.y + spacing * (size - 1) * 0.5)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd and _shader.is_valid():
		if _levels_rd:
			_levels_rd.texture_rd_rid = RID()
		if _water_rd:
			_water_rd.texture_rd_rid = RID()
		var rids: Array[RID] = [_set, _levels_tex, _water_tex]
		rids.append_array(_buffers)
		rids.append_array([_biome_buffer, _pipeline, _shader])
		var rd := _rd
		RenderingServer.call_on_render_thread(func() -> void:
			for rid in rids:
				if rid.is_valid():
					rd.free_rid(rid))
