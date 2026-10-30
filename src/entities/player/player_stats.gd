class_name PlayerStats
extends Node
## The player's condition and records (the parent Player's). Breath: it runs
## out while the head is under (over breath_capacity() seconds: the breath-hold
## plus whatever held gear adds) and comes back in 3 s above water; at none
## the player drowns (`drowned`, and Events.player_drowned). And running
## totals, for journals, achievements, skill progression and the save file.

signal drowned

const BREATH_BACK := 3.0                  ## s to get your breath back above water.

@export var breath_seconds := 20.0        ## Breath-hold without gear.
var breath := 1.0                         ## 0..1 of a lungful.

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


## Seconds of air: breath-hold plus whatever held or worn gear adds.
func breath_capacity() -> float:
	return breath_seconds + _player.gear_stat(&"breath_seconds")


func refill_breath() -> void:
	breath = 1.0


func _physics_process(delta: float) -> void:
	if _player.head_under:
		breath -= delta / breath_capacity()
		if breath <= 0.0:
			breath = 0.0
			times_drowned += 1
			drowned.emit()
			_player.emit_event(&"player_drowned")
	else:
		breath = minf(1.0, breath + delta / BREATH_BACK)
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
