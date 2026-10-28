class_name LoadingScreen
extends CanvasLayer
## Covers everything while the world generates: a title, what's being done
## and a progress bar.

var progress := 0.0:
	set(v):
		progress = v
		if _bar:
			_bar.value = v
var stage := "":
	set(v):
		stage = v
		if _stage:
			_stage.text = v

var _bar: ProgressBar
var _stage: Label


func _ready() -> void:
	layer = 100
	var back := ColorRect.new()
	back.color = Color(0.03, 0.06, 0.1)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(520, 0)
	box.position = -Vector2(260, 60)
	box.add_theme_constant_override("separation", 14)
	back.add_child(box)
	var title := Label.new()
	title.text = "Generating the world"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	box.add_child(title)
	_bar = ProgressBar.new()
	_bar.max_value = 1.0
	_bar.value = progress
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(520, 14)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.08)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.78, 1.0)
	_bar.add_theme_stylebox_override("background", bg)
	_bar.add_theme_stylebox_override("fill", fill)
	box.add_child(_bar)
	_stage = Label.new()
	_stage.text = stage
	_stage.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_stage)
