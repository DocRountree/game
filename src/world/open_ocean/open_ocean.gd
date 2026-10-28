extends Node3D
## Open-ocean sandbox: wires player, boat, camera and HUD together and
## scatters floating crates. Registers itself with Game as the running world.
## While the world generates, a loading screen covers everything and the
## player, boat and crates wait, frozen and hidden; then the boat is moored at
## the spawn point and the player stands on the nearest gentle dry ground.

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
@onready var terrain: Terrain = $Terrain


func _enter_tree() -> void:
	# before any child's _ready, so systems see this world's config
	Game.begin_world(self, world_config)


func _exit_tree() -> void:
	Game.end_world(self)


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Settings.apply_to_viewport(get_viewport())
	add_child(DebugOverlay.new())   # F3
	var world_map := WorldMapView.new()   # F4
	world_map.target = player
	add_child(world_map)
	var sun: DirectionalLight3D = $Sun
	sun.directional_shadow_max_distance = QualitySettings.current().shadow_distance
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true   # no hard seams between shadow cascades
	sun.directional_shadow_fade_start = 0.7
	sun.directional_shadow_split_1 = 0.06   # sharp shadows near, coarser far
	sun.directional_shadow_split_2 = 0.18
	sun.directional_shadow_split_3 = 0.45
	RenderingServer.directional_shadow_atlas_set_size(8192, true)
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
	_loading = LoadingScreen.new()
	add_child(_loading)
	_freeze(true)
	terrain.maps_ready.connect(_on_world_ready)
	if Terrain.maps():
		_on_world_ready()


var _loading: LoadingScreen
var _spawn_spot := Vector3.INF   # where the player will stand, once the ground is solid there


func _freeze(on: bool) -> void:
	for n: Node3D in [player, boat, $Crates]:
		n.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT
		n.visible = not on
	hud.visible = not on
	if not on:
		player.model.visible = not camera.first_person


func _on_world_ready() -> void:
	if _spawn_spot != Vector3.INF:
		return
	boat.global_position = Vector3(0.0, 0.3, 0.0)
	_spawn_spot = _shore_spot()
	player.global_position = _spawn_spot + Vector3.UP * 2.0   # (the collider builds around the player)


# The nearest gentle dry ground to the spawn point (the boat), looking outward
# in rings: above the beach, not in a river, not steep.
func _shore_spot() -> Vector3:
	var maps := Terrain.maps()
	for r in range(40, 20000, 40):
		var steps := maxi(int(TAU * r / 40.0), 8)
		for k in steps:
			var a := TAU * k / steps
			var p := Vector2(cos(a), sin(a)) * r
			var h := maps.height_at(p.x, p.y)
			if h < 2.0 or h > 60.0 or not maps.river_at(p.x, p.y).is_empty() and float(maps.river_at(p.x, p.y).r) < 3.0:
				continue
			var gx := maps.height_at(p.x + 15.0, p.y) - maps.height_at(p.x - 15.0, p.y)
			var gz := maps.height_at(p.x, p.y + 15.0) - maps.height_at(p.x, p.y - 15.0)
			if absf(gx) < 3.0 and absf(gz) < 3.0:
				return Vector3(p.x, h, p.y)
	return Vector3(0.0, 1.0, 0.0)


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
	if _loading:
		_loading.progress = terrain.progress
		if _spawn_spot == Vector3.INF:
			_loading.stage = terrain.stage.capitalize()
		if _spawn_spot != Vector3.INF:
			_loading.stage = "Finding solid ground"
			player.global_position = _spawn_spot + Vector3.UP * 2.0
			if terrain.collider_covers(_spawn_spot.x, _spawn_spot.z):
				player.respawn(Vector3(_spawn_spot.x, Terrain.height_at(_spawn_spot.x, _spawn_spot.z) + 1.2, _spawn_spot.z))
				# face the boat
				var to_boat := boat.global_position - player.global_position
				camera.yaw = atan2(-to_boat.x, -to_boat.z)
				_freeze(false)
				_loading.queue_free()
				_loading = null
				hud.flash("Your boat is moored in the bay: right-click near it to climb aboard", 5.0)
	_underwater_view()
	var driving := player.boat != null
	camera.target = boat if driving else player
	camera.turn_with_target = driving
	camera.distance = 9.0 if driving else 4.5
	camera.target_offset = Vector3(0, 2.4, 0) if driving else Vector3(0, 0.5, 0)
	var extra := "\nmoon   " + atmosphere.moon_phase_text()
	hud.refresh(player, boat, clock.time_text() + extra)


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
