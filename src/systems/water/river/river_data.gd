class_name RiverData
extends RefCounted
## One generated river (WorldData builds them on load, downstream order):
## its centreline points (x, water level, z) and, per point, half width,
## depth, current and how far down a waterfall's face it is; its falls; the
## river it runs into.

var points := PackedVector3Array()
var half_width := PackedFloat32Array()
var depth := PackedFloat32Array()
var speed := PackedFloat32Array()   ## Current (m/s), precomputed (current()).
var riser := PackedFloat32Array()   ## How far down a fall's face (0 at its lip, 1 at its foot; -1 off them).
var falls: Array[FallData] = []
var joins := -1                     ## Index of the river it runs into (-1: the sea).


func _init(pts := PackedVector3Array(), hw := PackedFloat32Array(), dep := PackedFloat32Array(),
		ris := PackedFloat32Array(), fall_ranges: Array[Vector2i] = [], joins_river := -1) -> void:
	points = pts
	half_width = hw
	depth = dep
	riser = ris
	if riser.size() != points.size():
		riser.resize(points.size())
		riser.fill(-1.0)
	joins = joins_river
	for f in fall_ranges:
		falls.append(FallData.new(self, f.x, f.y))
	speed = current(points, half_width, riser) if points.size() > 1 else PackedFloat32Array()


## The fall whose face holds point k, or null.
func fall_at(k: int) -> FallData:
	for f in falls:
		if k >= f.first and k <= f.last:
			return f
	return null


## The river's mouth (its last point).
func mouth() -> Vector3:
	return points[points.size() - 1]


## A river's current (m/s) at each point: faster where the water falls (the
## drop over 80 m of it, not counting waterfalls), bigger rivers a little
## faster, and smoothed over about 120 m, so it never changes abruptly from
## one point to the next (however unevenly the points are spaced). Below a
## waterfall the water gathers in its pool and picks its current up again
## over a few widths.
static func current(pts: PackedVector3Array, hw: PackedFloat32Array, ris: PackedFloat32Array) -> PackedFloat32Array:
	var n := pts.size()
	var arc := PackedFloat32Array([0.0])
	for k in range(1, n):
		arc.append(arc[k - 1] + Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length())
	# the level with its waterfalls taken out (a fall doesn't speed a river up)
	var lvl := PackedFloat32Array([pts[0].y])
	var since_fall := PackedFloat32Array([1e9])
	for k in range(1, n):
		var drop := pts[k - 1].y - pts[k].y
		var run := arc[k] - arc[k - 1]
		var fall := ris[k] > 0.0
		lvl.append(lvl[k - 1] - (0.0 if fall else drop))
		since_fall.append(0.0 if fall else since_fall[k - 1] + run)
	var raw := PackedFloat32Array()
	var a := 0
	var b := 0
	for k in n:
		while a < k and arc[k] - arc[a] > 40.0:
			a += 1
		while b < n - 1 and arc[b] - arc[k] < 40.0:
			b += 1
		var slope := maxf(lvl[a] - lvl[b], 0.0) / maxf(arc[b] - arc[a], 1.0)
		raw.append(clampf(0.5 + 0.02 * hw[k] + 9.0 * sqrt(slope), 0.5, 6.0))
	var out := PackedFloat32Array()
	a = 0
	b = 0
	var sum := 0.0
	for k in n:
		# a running mean over +-60 m
		while b < n and arc[b] - arc[k] <= 60.0:
			sum += raw[b]
			b += 1
		while arc[k] - arc[a] > 60.0:
			sum -= raw[a]
			a += 1
		out.append(sum / (b - a) * lerpf(0.2, 1.0, smoothstep(0.0, 4.0 * hw[k] + 20.0, since_fall[k])))
	return out
