class_name BreathGauge
extends Control
## Breath as a round gauge: a disc that fills from the bottom up, like water
## rising in it (full = all the breath you have).

@export var value := 1.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if not is_equal_approx(v, value):
			value = v
			queue_redraw()
@export var fill_color := Color(0.35, 0.78, 1.0)
@export var back_color := Color(0.08, 0.08, 0.08, 0.7)
@export var rim_color := Color(0.0, 0.0, 0.0, 0.8)

const SEGMENTS := 48


func _draw() -> void:
	var r := minf(size.x, size.y) * 0.5
	var c := size * 0.5
	draw_circle(c, r, back_color)
	if value > 0.0:
		# the part of the disc below the level: the arc under the waterline,
		# closed by the waterline itself
		var level := c.y + r - 2.0 * r * value     # y of the waterline
		var h := clampf((level - c.y) / r, -1.0, 1.0)
		var a := asin(h)                          # angle of the waterline's ends
		var pts := PackedVector2Array()
		for k in SEGMENTS + 1:
			var t := lerpf(a, PI - a, float(k) / SEGMENTS)
			pts.append(c + Vector2(cos(t), sin(t)) * r)
		if pts.size() >= 3:
			draw_colored_polygon(pts, fill_color)
	draw_arc(c, r, 0.0, TAU, SEGMENTS, rim_color, 2.0, true)
