extends Node
## Performance tracker: smoothed frame timings and render counts, sampled a
## few times a second. Groundwork for dynamic resolution and LOD decisions,
## and for a debug overlay; nothing reacts to it yet.

const SAMPLE_INTERVAL := 0.5

var fps := 0.0
var frame_ms := 0.0          ## Smoothed CPU frame time.
var draw_calls := 0
var primitives := 0
var objects_drawn := 0

var _accum := 0.0


func _process(delta: float) -> void:
	frame_ms = lerpf(frame_ms, delta * 1000.0, 0.1)
	_accum += delta
	if _accum < SAMPLE_INTERVAL:
		return
	_accum = 0.0
	fps = Performance.get_monitor(Performance.TIME_FPS)
	draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	primitives = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	objects_drawn = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
