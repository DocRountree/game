class_name DebugOverlay
extends CanvasLayer
## F3: a corner readout of performance, like Minecraft's debug screen. Frame
## rate, CPU time per frame (game logic, physics, render submission), GPU time
## per frame, memory and video memory, draw calls. Godot reports CPU as time per
## frame, not as a share of the machine.

const REFRESH := 0.5

var _label := Label.new()
var _accum := 0.0


func _ready() -> void:
	layer = 100
	visible = false
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.anchor_top = 1.0
	_label.anchor_bottom = 1.0
	_label.offset_left = 10.0
	_label.offset_top = -170.0
	_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_label)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_overlay"):
		visible = not visible
		_accum = REFRESH


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum < REFRESH:
		return
	_accum = 0.0
	var vp := get_viewport().get_viewport_rid()
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	var render_cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
	var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_label.text = "%d fps  (%.1f ms)\nCPU  %.1f ms  (logic %.1f, physics %.1f, render %.1f)\nGPU  %.1f ms  %s\nRAM  %.0f MB    VRAM  %.0f MB\ndraw calls %d    objects %d" % [
		fps, 1000.0 / maxf(fps, 1.0), process_ms + physics_ms + render_cpu_ms, process_ms, physics_ms, render_cpu_ms,
		gpu_ms, RenderingServer.get_video_adapter_name(), mem, vram, draws, objects]
