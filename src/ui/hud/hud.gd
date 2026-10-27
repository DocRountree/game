class_name Hud
extends CanvasLayer
## Status readout, breath bar, contextual controls and flash messages.

@onready var _status: Label = $Status
@onready var _breath: ProgressBar = $Breath
@onready var _help: Label = $Help
@onready var _message: Label = $Message

var _message_time := 0.0


func refresh(player: Player, boat: Boat, time_text: String) -> void:
	var depth := player.head_depth()
	_status.text = "state  %s\nhead   %s\nboat   %.1f kn\ntime   %s" % [
		player.state, ("%.1f m under" % depth) if depth > 0.0 else "above water", boat.speed() * 1.944, time_text]
	_breath.value = player.breath
	_help.text = ("W/S throttle   A/D steer   SHIFT jump off" if player.boat else
			"WASD swim (look down to dive)   CTRL sprint   SPACE up   SHIFT down   RIGHT-CLICK board") \
			+ "\nmouse look (ESC frees)   F5 view   F6 aurora   F7 weather   M meteors   [ ] time of day   R respawn"


func flash(text: String, seconds := 2.5) -> void:
	_message.text = text
	_message_time = seconds


func _process(delta: float) -> void:
	_message_time -= delta
	_message.visible = _message_time > 0.0
