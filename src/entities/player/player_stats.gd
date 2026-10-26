class_name PlayerStats
extends Node
## Running totals about the player (the parent), for journals, achievements,
## skill progression and the save file. Observes only; changes nothing.

@export var distance_swum_m := 0.0
@export var distance_boated_m := 0.0
@export var seconds_in_water := 0.0       ## Swimming or floating (not aboard).
@export var seconds_submerged := 0.0      ## Head under.
@export var max_depth_m := 0.0            ## Deepest the head has been.
@export var times_drowned := 0
@export var boats_boarded := 0
## Water kinds visited (WaterBody.Kind values) and biome ids seen.
@export var waters_visited: Array[int] = []
@export var biomes_visited: Array[StringName] = []

var _player: Player
var _last_pos := Vector3.INF
var _was_aboard := false


func _ready() -> void:
	_player = get_parent() as Player
	_player.drowned.connect(func() -> void: times_drowned += 1)


func _physics_process(delta: float) -> void:
	var pos := _player.global_position
	var step := 0.0 if _last_pos == Vector3.INF else Vector2(pos.x - _last_pos.x, pos.z - _last_pos.z).length()
	_last_pos = pos
	if step > 20.0:   # respawn or teleport, not travel
		step = 0.0
	var aboard := _player.boat != null
	if aboard and not _was_aboard:
		boats_boarded += 1
	_was_aboard = aboard
	if aboard:
		distance_boated_m += step
	elif _player.water and _player.submerged(_player.water_height) > 0.0:
		distance_swum_m += step
		seconds_in_water += delta
	if _player.head_under:
		seconds_submerged += delta
		max_depth_m = maxf(max_depth_m, _player.head_depth())
	var w := _player.water
	if w:
		if not waters_visited.has(w.kind):
			waters_visited.append(w.kind)
		if w.biome and not biomes_visited.has(w.biome.id):
			biomes_visited.append(w.biome.id)


func to_dict() -> Dictionary:
	var d := {}
	for p in get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and p.usage & PROPERTY_USAGE_STORAGE:
			d[p.name] = get(p.name)
	return d


func from_dict(d: Dictionary) -> void:
	for k: String in d:
		set(k, d[k])
