class_name ChunkStreamer
extends Node3D
## Streams world content in square chunks round the camera: every registered
## ChunkSpawner gets the chunks within its view distance built (a few a frame,
## nearest first) and the ones well beyond it freed. One place for all
## distance-based content, so each new kind (plants, animals, structures,
## items) is only a spawner.

const CHUNK := 512.0                ## Chunk side (m).
const BUILDS_PER_FRAME := 24        ## At most this many chunks built a frame.
const KEEP_MARGIN := 600.0          ## Chunks are freed this far beyond their view.

var world_size := 20480.0
var _spawners: Array[ChunkSpawner] = []
var _loaded: Array[Dictionary] = []   # per spawner: Vector2i -> Node3D (or null: empty)
var _focus := Vector2(INF, INF)


## Stream a spawner's content from now on.
func add_spawner(s: ChunkSpawner) -> void:
	_spawners.append(s)
	_loaded.append({})


## Build everything within view of `at` at once (before putting someone there).
func prepare_at(at: Vector3) -> void:
	_update(Vector2(at.x, at.z), 1 << 30)


func loaded_count(spawner: int) -> int:
	return _loaded[spawner].size()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam:
		_update(Vector2(cam.global_position.x, cam.global_position.z), BUILDS_PER_FRAME)


func _update(at: Vector2, budget: int) -> void:
	var per_side := ceili(world_size / CHUNK)
	var half := world_size * 0.5
	for si in _spawners.size():
		var sp := _spawners[si]
		var loaded := _loaded[si]
		# free what's well out of view
		for key: Vector2i in loaded.keys():
			if _chunk_distance(key, at) > sp.view + KEEP_MARGIN:
				var n: Node3D = loaded[key]
				if n:
					n.queue_free()
				loaded.erase(key)
		# build what's in view and missing, nearest first
		var want: Array[Vector2i] = []
		var r := ceili(sp.view / CHUNK) + 1
		var c := Vector2i(floori((at.x + half) / CHUNK), floori((at.y + half) / CHUNK))
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var key := c + Vector2i(dx, dz)
				if key.x < 0 or key.y < 0 or key.x >= per_side or key.y >= per_side or loaded.has(key):
					continue
				if _chunk_distance(key, at) <= sp.view:
					want.append(key)
		want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _chunk_distance(a, at) < _chunk_distance(b, at))
		for key in want:
			if budget <= 0:
				return
			var rect := Rect2(key.x * CHUNK - half, key.y * CHUNK - half, CHUNK, CHUNK)
			var centre := Vector3(rect.get_center().x, 0.0, rect.get_center().y)
			var node := sp.build(key.x, key.y, rect, centre)
			if node:
				node.position = centre
				add_child(node)
			loaded[key] = node
			budget -= 1


func _chunk_distance(key: Vector2i, at: Vector2) -> float:
	var half := world_size * 0.5
	var lo := Vector2(key.x * CHUNK - half, key.y * CHUNK - half)
	var dx := maxf(0.0, maxf(lo.x - at.x, at.x - lo.x - CHUNK))
	var dz := maxf(0.0, maxf(lo.y - at.y, at.y - lo.y - CHUNK))
	return sqrt(dx * dx + dz * dz)
