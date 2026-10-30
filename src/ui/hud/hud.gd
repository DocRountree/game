class_name Hud
extends CanvasLayer
## Status readout, breath gauge, contextual controls and flash messages. It
## reads what it shows itself each frame (the player it's given, their boat
## or the nearest, the clock and the sky) and listens for messages
## (Events.message) and full-screen panels (Events.panel_open_changed, when
## it steps aside).

@export var player: Player
@export var atmosphere: Atmosphere

@onready var _status: Label = $Status
@onready var _breath: BreathGauge = $Breath
@onready var _help: Label = $Help
@onready var _message: Label = $Message

var _message_time := 0.0


func _ready() -> void:
	var events := get_node_or_null(^"/root/Events")
	if events:
		events.message.connect(flash)
		events.panel_open_changed.connect(func(open: bool) -> void: visible = not open)


func flash(text: String, seconds := 2.5) -> void:
	_message.text = text
	_message_time = seconds


func _process(delta: float) -> void:
	_message_time -= delta
	_message.visible = _message_time > 0.0
	if player:
		_refresh()


func _refresh() -> void:
	var boat := player.boat
	if boat == null:
		var boats := get_tree().get_nodes_in_group(&"boats")
		boat = boats[0] if not boats.is_empty() else null
	var clock := GameClock.current()
	var time_text := (clock.time_text() if clock else "") + ("\nmoon   " + atmosphere.moon_phase_text() if atmosphere else "")
	var depth := player.head_depth()
	_status.text = "state  %s (%s)\nhead   %s\nfall   %.1f m/s\nboat   %.1f kn\ntime   %s" % [
		player.state.to_lower(), player.pose.to_lower(), ("%.1f m under" % depth) if depth > 0.0 else "above water",
		maxf(-player.velocity.y, 0.0), boat.speed() * 1.944 if boat else 0.0, time_text]
	_breath.value = player.stats.breath
	var help := ""
	match player.state:
		&"DRIVE": help = "W/S throttle   A/D steer   SHIFT jump off"
		&"CLIMB", &"MANTLE": help = "WASD climb   CTRL faster   E let go"
		&"FLY": help = "WASD fly   SPACE up   SHIFT down   CTRL faster   SPACE SPACE stop flying"
		_:
			if player.pose == &"WALKING" or player.pose == &"AIRBORNE":
				help = "WASD walk   CTRL sprint   SHIFT sneak   SPACE jump   SPACE SPACE fly   E climb   RIGHT-CLICK board"
			else:
				help = "WASD swim (look down to dive)   CTRL sprint   SPACE up   SHIFT down   RIGHT-CLICK board"
	_help.text = help + "\nmouse look (ESC frees)   F3 perf   F5 view   F6 aurora   M meteors   C character   [ ] time of day   R respawn"
