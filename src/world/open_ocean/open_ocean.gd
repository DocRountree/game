extends Node3D
## Open-ocean sandbox: wires player, boat, camera and HUD together and
## scatters floating crates.

@export var crate_scene: PackedScene
@export var crate_count := 30
@export var crate_spread := 90.0

@onready var player: Player = $Player
@onready var boat: Boat = $Boat
@onready var camera: ThirdPersonCamera = $Camera
@onready var hud: Hud = $HUD
@onready var atmosphere: Atmosphere = $Atmosphere


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in crate_count:
		var crate: Node3D = crate_scene.instantiate()
		crate.position = Vector3(rng.randf_range(-crate_spread, crate_spread), 0.0,
				rng.randf_range(-crate_spread, crate_spread))
		crate.rotation.y = rng.randf() * PI
		$Crates.add_child(crate)
	player.drowned.connect(_on_player_drowned)
	hud.flash("Press E near the boat to climb aboard", 4.0)


func _process(_delta: float) -> void:
	var driving := player.boat != null
	camera.target = boat if driving else player
	camera.follow_heading = driving
	camera.distance = 9.0 if driving else 4.5
	camera.target_offset = Vector3(0, 2.4, 0) if driving else Vector3(0, 0.5, 0)
	hud.refresh(player, boat, atmosphere.time_text())


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
