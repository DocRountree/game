class_name CharacterPicker
extends CanvasLayer
## C in the debug world: style the player's character. A panel down the right
## (height and build; skin, from a row of skin tones or a row of simple
## colours red to violet; hair length, curl, colour and style; facial hair;
## hat; accessories, each with its colour; clothes) with a camera facing the
## character, who stands still while it's open (drag on the view to turn
## them). Every change shows at once: colours only reset the palette, shape
## changes rebuild the hair and the rest (at most every REBUILD_EVERY s while a
## slider is dragged). Done saves the look (save_path); C or Esc closes it too.

const REBUILD_EVERY := 0.06
const SWATCH := 22

var save_path := Player.SAVED_TRAITS
var is_open := false
var player: Player
var traits: CharacterTraits

# controls (named, so tests and tools can drive them)
var height_slider: HSlider
var build_slider: HSlider
var hair_length_slider: HSlider
var hair_curl_slider: HSlider
var hair_style: OptionButton
var facial_hair: OptionButton
var facial_hair_slider: HSlider
var hat: OptionButton
var accessory_checks := {}   # id -> CheckBox
var _hat_ids: Array[String] = []     # (the hat option's items: "none", then each HAT AccessoryDef)
var _style_ids: Array[String] = []   # ("", then each STYLE AccessoryDef)

var _camera: Camera3D
var _prev_camera: Camera3D
var _prev_mouse := Input.MOUSE_MODE_VISIBLE
var _prev_visible := true
var _before: CharacterTraits
var _dirty_shape := false
var _since_rebuild := 0.0
var _face := false
var _panel: PanelContainer
var _swatch_groups := {}   # group -> Array of [Button, Color]
var _syncing := false


func _ready() -> void:
	layer = 50
	visible = false
	_build_ui()


func toggle(p: Player) -> void:
	if is_open:
		close()
	else:
		open(p)


func open(p: Player) -> void:
	if is_open:
		return
	player = p
	if player.traits == null:
		player.traits = CharacterTraits.new()
	traits = player.traits
	_before = traits.duplicate(true)
	is_open = true
	visible = true
	player.input_locked = true
	player.locked_facing = player.model.rotation.y
	_prev_visible = player.model.visible
	player.model.visible = true
	_prev_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_prev_camera = player.get_viewport().get_camera_3d()
	_camera = Camera3D.new()
	_camera.name = "PickerCamera"
	_camera.fov = 40.0
	player.get_parent().add_child(_camera)
	_place_camera()
	_camera.current = true
	_sync_controls()
	_panel_event(true)


func close(save := true) -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	if _dirty_shape:
		_apply(true)
	if save:
		ResourceSaver.save(traits, save_path)
	player.input_locked = false
	player.model.visible = _prev_visible
	Input.mouse_mode = _prev_mouse
	if _prev_camera:
		_prev_camera.current = true
	_camera.queue_free()
	_camera = null
	_panel_event(false)


func _panel_event(open_: bool) -> void:
	var events := get_node_or_null(^"/root/Events")
	if events:
		events.panel_open_changed.emit(open_)


func _place_camera() -> void:
	var f := player.locked_facing
	# the camera stays put in front of where they faced on opening; turning
	# them turns the body, not the view
	if not _camera.has_meta(&"front"):
		_camera.set_meta(&"front", Vector3(-sin(f), 0.0, -cos(f)))
	var front: Vector3 = _camera.get_meta(&"front")
	var s := player.model.scale.y
	var focus := player.model.global_position + Vector3(0, (0.31 if _face else -0.05) * s, 0)
	var dist := (0.9 if _face else 3.0) * s
	_camera.global_position = focus + front * dist + Vector3(0, 0.05 * s, 0)
	_camera.look_at(focus)
	_camera.h_offset = 0.32 * dist / 3.0   # (the character left of the panel)


func _process(delta: float) -> void:
	if not is_open:
		return
	_since_rebuild += delta
	if _dirty_shape and _since_rebuild >= REBUILD_EVERY:
		_apply(true)
	_place_camera()


func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		player.locked_facing += event.relative.x * 0.01
		get_viewport().set_input_as_handled()


## Apply the traits: the shape (hair, hat ...) rebuilt, or only the colours.
func _apply(shape: bool) -> void:
	if shape:
		traits.apply_to(player.model)
		_dirty_shape = false
		_since_rebuild = 0.0
	else:
		var mat := player.model.get_meta(&"character_material", null) as ShaderMaterial
		if mat:
			mat.set_shader_parameter("palette", traits.palette())


func _shape_changed() -> void:
	if not _syncing:
		_dirty_shape = true


func _color_changed() -> void:
	if not _syncing:
		_apply(false)


# --- the panel --------------------------------------------------------------------

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -360.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.88)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
	var title := Label.new()
	title.text = "Character"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	var hint := Label.new()
	hint.text = "Drag the view to turn them.  C or Esc closes."
	hint.modulate = Color(1, 1, 1, 0.6)
	box.add_child(hint)

	_heading(box, "Body")
	height_slider = _slider(box, "Height", 1.4, 2.1, 0.01, func(v: float) -> void:
		traits.height = v
		_shape_changed())
	build_slider = _slider(box, "Build", 0.7, 1.4, 0.01, func(v: float) -> void:
		traits.build = v
		_shape_changed())

	_heading(box, "Skin")
	box.add_child(_swatches("skin", CharacterTraits.SKIN_TONES, func(c: Color) -> void:
		traits.skin_color = c
		_color_changed()))
	box.add_child(_swatches("skin", CharacterTraits.BRIGHT_COLORS, func(c: Color) -> void:
		traits.skin_color = c
		_color_changed()))

	_heading(box, "Hair")
	hair_length_slider = _slider(box, "Length", 0.0, 1.0, 0.01, func(v: float) -> void:
		traits.hair_length = v
		_shape_changed())
	hair_curl_slider = _slider(box, "Curl", 0.0, 1.0, 0.01, func(v: float) -> void:
		traits.hair_curl = v
		_shape_changed())
	box.add_child(_swatches("hair", CharacterTraits.HAIR_COLORS, func(c: Color) -> void:
		traits.hair_color = c
		_color_changed()))
	box.add_child(_swatches("hair", CharacterTraits.BRIGHT_COLORS, func(c: Color) -> void:
		traits.hair_color = c
		_color_changed()))
	var style_names := ["Loose"]
	_style_ids = [""]
	for d: AccessoryDef in CharacterTraits.defs(AccessoryDef.Kind.STYLE):
		style_names.append(d.display_name)
		_style_ids.append(String(d.id))
	hair_style = _options(box, "Style", style_names, func(i: int) -> void:
		for id in _style_ids:
			traits.accessories.erase(id)
		if _style_ids[i] != "":
			traits.accessories.append(_style_ids[i])
		_shape_changed())

	_heading(box, "Facial hair")
	facial_hair = _options(box, "Kind", ["None", "Stubble", "Moustache", "Goatee", "Beard"], func(i: int) -> void:
		traits.facial_hair = i as CharacterTraits.FacialHair
		_shape_changed())
	facial_hair_slider = _slider(box, "Length", 0.0, 1.0, 0.01, func(v: float) -> void:
		traits.facial_hair_length = v
		_shape_changed())

	_heading(box, "Hat")
	var hat_names: Array[String] = ["None"]
	_hat_ids = ["none"]
	for d: AccessoryDef in CharacterTraits.defs(AccessoryDef.Kind.HAT):
		hat_names.append(d.display_name)
		_hat_ids.append(String(d.id))
	hat = _options(box, "Hat", hat_names, func(i: int) -> void:
		traits.hat = _hat_ids[i]
		_shape_changed())
	box.add_child(_swatches("hat", CharacterTraits.ACCESSORY_COLORS, func(c: Color) -> void:
		traits.hat_color = c
		_color_changed()))

	_heading(box, "Accessories")
	for d: AccessoryDef in CharacterTraits.defs(AccessoryDef.Kind.ACCESSORY):
		var id := String(d.id)
		var check := CheckBox.new()
		check.text = d.display_name
		check.toggled.connect(func(on: bool) -> void:
			if _syncing:
				return
			traits.accessories.erase(id)
			if on:
				traits.accessories.append(id)
			_shape_changed())
		box.add_child(check)
		accessory_checks[id] = check
		box.add_child(_swatches("acc_" + id, CharacterTraits.ACCESSORY_COLORS, func(c: Color) -> void:
			traits.accessory_colors[id] = c
			_color_changed(), SWATCH - 6))

	_heading(box, "Clothes")
	box.add_child(_swatches("shirt", CharacterTraits.BRIGHT_COLORS + CharacterTraits.ACCESSORY_COLORS, func(c: Color) -> void:
		traits.shirt_color = c
		_color_changed(), SWATCH - 6))
	box.add_child(_swatches("shorts", CharacterTraits.ACCESSORY_COLORS + CharacterTraits.BRIGHT_COLORS, func(c: Color) -> void:
		traits.shorts_color = c
		_color_changed(), SWATCH - 6))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	for b: Array in [["Randomise", randomise], ["Reset", reset], ["Face", toggle_face], ["Done", func() -> void: close()]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(b[1])
		buttons.add_child(btn)


func _heading(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.modulate = Color(1.0, 0.85, 0.55)
	box.add_child(l)


func _slider(box: VBoxContainer, text: String, lo: float, hi: float, step: float, on_change: Callable) -> HSlider:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 90
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			on_change.call(v))
	row.add_child(s)
	box.add_child(row)
	return s


func _options(box: VBoxContainer, text: String, items: Array, on_pick: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 90
	row.add_child(l)
	var o := OptionButton.new()
	for it: String in items:
		o.add_item(it)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.item_selected.connect(func(i: int) -> void:
		if not _syncing:
			on_pick.call(i))
	row.add_child(o)
	box.add_child(row)
	return o


func _swatches(group: String, colors: Array, on_pick: Callable, size := SWATCH) -> Control:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 3)
	flow.add_theme_constant_override("v_separation", 3)
	if not _swatch_groups.has(group):
		_swatch_groups[group] = []
	for c: Color in colors:
		var b := Button.new()
		b.custom_minimum_size = Vector2(size, size)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "#" + c.to_html(false)
		for state in ["normal", "hover", "pressed"]:
			var st := StyleBoxFlat.new()
			st.bg_color = c
			st.set_corner_radius_all(3)
			st.set_border_width_all(2 if state == "hover" else 0)
			st.border_color = Color.WHITE
			b.add_theme_stylebox_override(state, st)
		b.pressed.connect(func() -> void:
			on_pick.call(c)
			_mark(group, c))
		flow.add_child(b)
		_swatch_groups[group].append([b, c])
	return flow


# the chosen swatch of a group outlined
func _mark(group: String, c: Color) -> void:
	for entry: Array in _swatch_groups.get(group, []):
		var b: Button = entry[0]
		var st := b.get_theme_stylebox("normal") as StyleBoxFlat
		st.set_border_width_all(2 if (entry[1] as Color).is_equal_approx(c) else 0)


func _sync_controls() -> void:
	_syncing = true
	height_slider.value = traits.height
	build_slider.value = traits.build
	hair_length_slider.value = traits.hair_length
	hair_curl_slider.value = traits.hair_curl
	hair_style.select(maxi(_style_ids.find(traits.hair_style()), 0))
	facial_hair.select(traits.facial_hair)
	facial_hair_slider.value = traits.facial_hair_length
	hat.select(maxi(_hat_ids.find(traits.hat), 0))
	for id: String in accessory_checks:
		(accessory_checks[id] as CheckBox).button_pressed = traits.has_accessory(id)
	_mark("skin", traits.skin_color)
	_mark("hair", traits.hair_color)
	_mark("hat", traits.hat_color)
	_mark("shirt", traits.shirt_color)
	_mark("shorts", traits.shorts_color)
	for id: String in accessory_checks:
		_mark("acc_" + id, traits.accessory_color(id))
	_syncing = false


func randomise() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var r := CharacterTraits.generate(rng)
	r.height = traits.height   # (the body keeps its size: only the look changes)
	r.build = traits.build
	_copy(r)


func reset() -> void:
	_copy(_before)


func toggle_face() -> void:
	_face = not _face


func _copy(src: CharacterTraits) -> void:
	for prop in ["height", "build", "skin_color", "hair_color", "shirt_color", "shorts_color", "hair_length",
			"hair_curl", "facial_hair", "facial_hair_length", "hat", "hat_color"]:
		traits.set(prop, src.get(prop))
	traits.accessories = src.accessories.duplicate()
	traits.accessory_colors = src.accessory_colors.duplicate()
	_apply(true)
	_sync_controls()
