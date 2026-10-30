class_name DebugTools
extends Node
## The debug world's tools, kept out of the level: F3 the performance readout
## (DebugOverlay), F6 an aurora every night, M a meteor shower every night,
## C the character picker. A real game world leaves this node out.

@export var player: Player
@export var aurora: Aurora
@export var meteors: Meteors

var picker := CharacterPicker.new()


func _ready() -> void:
	add_child(DebugOverlay.new())
	picker.name = "CharacterPicker"
	add_child(picker)


func _unhandled_input(event: InputEvent) -> void:
	if picker.is_open:   # (the picker's own keys: C or Esc close it)
		if event.is_action_pressed(&"character_picker") or event.is_action_pressed(&"toggle_mouse"):
			picker.close()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"character_picker") and player and player.state != &"DRIVE":
		picker.open(player)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"debug_aurora") and aurora:
		aurora.set_forced(not aurora.forced)
		_say("Debug: aurora every night" if aurora.forced else "Debug: auroras by chance (1 in 50)")
	elif event.is_action_pressed(&"debug_meteors") and meteors:
		meteors.set_forced_shower(not meteors.forced_shower)
		_say("Debug: meteor shower every night" if meteors.forced_shower else "Debug: meteor showers by chance (1 in 50)")


func _say(text: String) -> void:
	var events := get_node_or_null(^"/root/Events")
	if events:
		events.message.emit(text, 2.5)
