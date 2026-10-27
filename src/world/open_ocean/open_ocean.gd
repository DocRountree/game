extends Node3D
## Open-ocean sandbox: wires player, boat, camera and HUD together and
## scatters floating crates. Registers itself with Game as the running world.

@export var world_config: WorldConfig
@export var crate_scene: PackedScene
@export var crate_count := 30
@export var crate_spread := 90.0

@onready var player: Player = $Player
@onready var boat: Boat = $Boat
@onready var camera: PlayerCamera = $Camera
@onready var hud: Hud = $HUD
@onready var atmosphere: Atmosphere = $Atmosphere
@onready var clock: GameClock = $Clock


func _enter_tree() -> void:
	# before any child's _ready, so systems see this world's config
	Game.begin_world(self, world_config)


func _exit_tree() -> void:
	Game.end_world(self)


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Settings.apply_to_viewport(get_viewport())
	$Sun.directional_shadow_max_distance = QualitySettings.current().shadow_distance
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in crate_count:
		var crate: Node3D = crate_scene.instantiate()
		crate.position = Vector3(rng.randf_range(-crate_spread, crate_spread), 0.0,
				rng.randf_range(-crate_spread, crate_spread))
		crate.rotation.y = rng.randf() * PI
		$Crates.add_child(crate)
	camera.yaw = PI   # face south, toward the noon sun
	camera.eyes = player.get_node("Model/Head")
	_set_first_person(true)   # start looking out of your own eyes
	player.drowned.connect(_on_player_drowned)
	hud.flash("Right-click near the boat to climb aboard", 4.0)


var _air_fog := {}


# Under the surface the view closes in to a blue-green murk.
func _underwater_view() -> void:
	var env: Environment = $WorldEnvironment.environment
	if _air_fog.is_empty():
		_air_fog = {"d": env.fog_density, "c": env.fog_light_color, "a": env.fog_aerial_perspective, "s": env.fog_sky_affect}
	var eye := camera.global_position
	var under := eye.y < Water.surface_height(eye.x, eye.z)
	var day := clampf(($Sun as DirectionalLight3D).light_energy, 0.05, 1.0)
	env.fog_density = 0.06 if under else _air_fog.d
	env.fog_light_color = Color(0.02, 0.16, 0.2) * day if under else _air_fog.c
	env.fog_aerial_perspective = 0.0 if under else _air_fog.a
	env.fog_sky_affect = 1.0 if under else _air_fog.s


func _process(_delta: float) -> void:
	_underwater_view()
	var driving := player.boat != null
	camera.target = boat if driving else player
	camera.turn_with_target = driving
	camera.distance = 9.0 if driving else 4.5
	camera.target_offset = Vector3(0, 2.4, 0) if driving else Vector3(0, 0.5, 0)
	hud.refresh(player, boat, clock.time_text() + "\nmoon   " + atmosphere.moon_phase_text())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"quit"):
		get_tree().quit()
	elif event.is_action_pressed(&"toggle_view"):
		_set_first_person(not camera.first_person)
	elif event.is_action_pressed(&"toggle_mouse"):
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if captured else Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(&"debug_aurora"):
		var aurora: Aurora = $Aurora
		aurora.set_forced(not aurora.forced)
		hud.flash("Debug: aurora every night" if aurora.forced else "Debug: auroras by chance (1 in 50)", 2.5)
	elif event.is_action_pressed(&"debug_meteors"):
		var meteors: Meteors = $Meteors
		meteors.set_forced_shower(not meteors.forced_shower)
		hud.flash("Debug: meteor shower every night" if meteors.forced_shower else "Debug: meteor showers by chance (1 in 50)", 2.5)
	elif event.is_action_pressed(&"debug_weather"):
		hud.flash("Debug: " + ($Weather as Weather).cycle_override(), 2.5)
	elif event.is_action_pressed(&"respawn"):
		_respawn_player()


func _set_first_person(on: bool) -> void:
	camera.first_person = on
	player.model.visible = not on   # don't look out through your own head
	Events.view_mode_changed.emit(on)


func _on_player_drowned() -> void:
	hud.flash("You drowned. Respawning beside the boat.", 3.0)
	_respawn_player()


func _respawn_player() -> void:
	player.respawn(boat.global_position + boat.global_basis.x * 3.0)
