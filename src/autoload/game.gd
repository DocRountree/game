extends Node
## Session state: the world currently loaded and its key actors, so systems
## can find them without hard-coded paths. Levels register themselves; nothing
## here owns gameplay.

var config: WorldConfig = WorldConfig.new()
var world: Node3D
var clock: GameClock
var player: Player


## Called by a level from _enter_tree, before its children run _ready.
func begin_world(level: Node3D, world_config: WorldConfig) -> void:
	world = level
	if world_config:
		config = world_config


func end_world(level: Node3D) -> void:
	if world == level:
		world = null
		clock = null
		player = null
