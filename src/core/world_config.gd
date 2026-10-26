@tool
class_name WorldConfig
extends Resource
## Facts about a world that many systems share: its seed (procedural
## generation), where it sits on the planet (latitude) and the one calendar
## day that repeats forever. A level assigns one; systems read it through
## WorldConfig.current(), which falls back to the defaults in the editor.

@export var world_seed := 1              ## Master seed; systems derive their own from it.
@export_range(-89.0, 89.0) var latitude := 35.0   ## Degrees north.
## Julian date of the repeating day's midnight (default: 2026 winter solstice).
@export var day_jd := 2461395.5
@export var planet_radius_m := 6400000.0 ## For horizon distance, sky and atmosphere maths.

static var _default: WorldConfig


## The running world's config, or defaults (editor previews, standalone tests).
static func current() -> WorldConfig:
	if not Engine.is_editor_hint():
		var game := _game()
		if game and game.config:
			return game.config
	if _default == null:
		_default = WorldConfig.new()
	return _default


## A per-system seed, so systems stay independent but reproducible.
func seed_for(system: String) -> int:
	return hash(str(world_seed) + ":" + system)


static func _game() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(^"Game") if tree else null
