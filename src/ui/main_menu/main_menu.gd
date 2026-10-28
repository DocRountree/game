class_name MainMenu
extends Control
## The first screen: start a game (not made yet) or enter debug mode (the
## open-ocean sandbox).

const DEBUG_WORLD := "res://src/world/open_ocean/open_ocean.tscn"


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var back := ColorRect.new()
	back.color = Color(0.03, 0.06, 0.1)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(320, 0)
	box.position = -Vector2(160, 90)
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	var title := Label.new()
	title.text = ProjectSettings.get_setting("application/config/name")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	box.add_child(title)
	var start := Button.new()
	start.text = "Start game"
	start.disabled = true
	start.tooltip_text = "Not available yet"
	start.custom_minimum_size = Vector2(320, 44)
	box.add_child(start)
	var debug := Button.new()
	debug.text = "Debug mode"
	debug.custom_minimum_size = Vector2(320, 44)
	debug.pressed.connect(func() -> void: get_tree().change_scene_to_file(DEBUG_WORLD))
	box.add_child(debug)
	var quit := Button.new()
	quit.text = "Quit"
	quit.custom_minimum_size = Vector2(320, 44)
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)
	debug.grab_focus()
