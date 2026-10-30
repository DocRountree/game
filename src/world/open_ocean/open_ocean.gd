extends Node3D
## The sandbox world: the generated islands (Terrain), the ocean and sky,
## the player and their boat. It only puts them together: the camera, the
## HUD, the debug tools and the underwater view keep their own rules. You
## start on a beach near the river mouth with the boat moored offshore;
## drowning or R puts you back beside the boat. Registers itself with Game
## as the running world.

@export var world_config: WorldConfig

@onready var player: Player = $Player
@onready var boat: Boat = $Boat
@onready var camera: PlayerCamera = $Camera
@onready var hud: Hud = $HUD
@onready var debug: DebugTools = $DebugTools


func _enter_tree() -> void:
	# before any child's _ready, so systems see this world's config
	Game.begin_world(self, world_config)


func _exit_tree() -> void:
	Game.end_world(self)


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Settings.apply_to_viewport(get_viewport())
	$Sun.directional_shadow_max_distance = QualitySettings.current().shadow_distance
	var world := WorldData.get_world()
	camera.yaw = PI   # face south, toward the noon sun
	if world:
		boat.global_position = Vector3(world.boat.x, 0.3, world.boat.y)
		var out := Vector2(world.boat.x - world.spawn.x, world.boat.y - world.spawn.y)
		boat.rotation.y = atan2(-out.x, -out.y)   # pointing out to sea
		var at := Vector3(world.spawn.x, 0.0, world.spawn.y)
		($World as WorldLoader).prepare_at(at)
		player.respawn(Vector3(at.x, Terrain.height_at(at.x, at.z) + 1.4, at.z))
		var to_boat := boat.global_position - player.global_position
		camera.yaw = atan2(-to_boat.x, -to_boat.z)   # facing the boat
	camera.first_person = true   # start looking out of your own eyes
	player.stats.drowned.connect(_on_player_drowned)
	hud.flash("Your boat is moored offshore: right-click near it to climb aboard", 5.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"quit"):
		get_tree().quit()
	elif event.is_action_pressed(&"toggle_mouse"):
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if captured else Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(&"respawn"):
		_respawn_player()


func _on_player_drowned() -> void:
	hud.flash("You drowned. Respawning beside the boat.", 3.0)
	_respawn_player()


func _respawn_player() -> void:
	player.respawn(boat.global_position + boat.global_basis.x * 3.0)
