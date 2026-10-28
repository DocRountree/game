class_name WorldMapView
extends CanvasLayer
## F4: the whole baked world as a map (sea depth, land by ground type, lakes,
## rivers blue, dry riverbeds tan) with a marker where the player is. A debug
## view for now; the explored-only player map will build on it.

const PX := 512

@export var target: Node3D

var _rect := TextureRect.new()
var _marker := ColorRect.new()


func _ready() -> void:
	layer = 90
	visible = false
	_rect.custom_minimum_size = Vector2(PX, PX)
	_rect.size = Vector2(PX, PX)
	_rect.set_anchors_preset(Control.PRESET_CENTER)
	_rect.position = -Vector2(PX, PX) * 0.5
	add_child(_rect)
	_marker.color = Color(1.0, 0.2, 0.2)
	_marker.size = Vector2(6, 6)
	_rect.add_child(_marker)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"world_map"):
		visible = not visible
		if visible and _rect.texture == null and Terrain.maps():
			_rect.texture = ImageTexture.create_from_image(Terrain.maps().to_image(PX))


func _process(_delta: float) -> void:
	var maps := Terrain.maps()
	if not visible or maps == null or target == null:
		return
	var p := target.global_position
	var uv := (maps.to_grid(p.x, p.z) + Vector2.ONE * 0.5) / maps.n
	_marker.position = uv * PX - _marker.size * 0.5
