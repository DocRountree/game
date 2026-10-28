class_name Hud
extends CanvasLayer
## Status readout, breath gauge, contextual controls and flash messages.

@onready var _status: Label = $Status
@onready var _breath: BreathGauge = $Breath
@onready var _help: Label = $Help
@onready var _message: Label = $Message

var _message_time := 0.0


func refresh(player: Player, boat: Boat, time_text: String) -> void:
	var depth := player.head_depth()
	_status.text = "state  %s\nhead   %s\nfall   %.1f m/s\nboat   %.1f kn\ntime   %s" % [
		player.state, ("%.1f m under" % depth) if depth > 0.0 else "above water", maxf(-player.velocity.y, 0.0),
		boat.speed() * 1.944, time_text]
	_breath.value = player.breath
	_help.text = ("W/S throttle   A/D steer   SHIFT jump off" if player.boat else
			("WASD fly   SPACE up   SHIFT down   CTRL faster   SPACE SPACE stop flying" if player.flying else
			"WASD walk   CTRL sprint   SHIFT sneak   SPACE jump   SPACE SPACE fly   RIGHT-CLICK board" if player.state in [&"WALKING", &"AIRBORNE"] else
			"WASD swim (look down to dive)   CTRL sprint   SPACE up   SHIFT down   RIGHT-CLICK board")) \
			+ "\nmouse look (ESC frees)   F3 perf   F4 map   F5 view   F6 aurora   M meteors   [ ] time of day   R respawn"


func flash(text: String, seconds := 2.5) -> void:
	_message.text = text
	_message_time = seconds


func _process(delta: float) -> void:
	_message_time -= delta
	_message.visible = _message_time > 0.0
