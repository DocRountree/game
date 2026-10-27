class_name RiverNetwork
extends RefCounted
## The baked rivers, oxbow lakes and meander scars as straight segments, with
## a coarse tile index so "which channel is near this point?" only looks at a
## handful. The terrain compute shader gets the same two arrays and answers
## the same question per texel, so the channels it carves, the water it draws
## and the water physics feels all come from one exact description: smooth
## banks at any resolution.

const TILE := 256.0          ## Tile side (m).
const SEG_FLOATS := 12       ## p0.x, p0.z, p1.x, p1.z, s0, s1, hw0, hw1, d0, d1, v0, v1
const REACH := 6.2           ## A segment is listed in tiles within this many half widths.

## Per segment: ends, water surface (or dry bed's would-be surface) at each
## end, half width, depth, and speed (m/s; -1 = dry bed).
var segments := PackedFloat32Array()
## Tile index: tile_count + 1 offsets, then segment indices.
var tiles := PackedInt32Array()
var tiles_per_side := 0
var corner := Vector2.ZERO   ## World xz of the tile grid's corner.


func _init(maps: WorldMaps) -> void:
	tiles_per_side = ceili(maps.size / TILE)
	corner = maps.center - Vector2.ONE * maps.size * 0.5
	for river in maps.rivers:
		var pts: PackedVector3Array = river.points
		var hw: PackedFloat32Array = river.half_width
		var dep: PackedFloat32Array = river.depth
		var spd: PackedFloat32Array = river.speed
		var wet: PackedByteArray = river.wet
		for k in pts.size() - 1:
			if Vector2(pts[k].x - pts[k + 1].x, pts[k].z - pts[k + 1].z).length_squared() < 0.01:
				continue
			segments.append_array([pts[k].x, pts[k].z, pts[k + 1].x, pts[k + 1].z,
					pts[k].y, pts[k + 1].y, hw[k], hw[k + 1], dep[k], dep[k + 1],
					spd[k] if wet[k] == 1 else -1.0, spd[k + 1] if wet[k + 1] == 1 else -1.0])
	_build_tiles()


func segment_count() -> int:
	return segments.size() / SEG_FLOATS


func _tile_range(i: int) -> Rect2i:
	var o := i * SEG_FLOATS
	var reach := maxf(segments[o + 6], segments[o + 7]) * REACH + 8.0
	var lo := Vector2(minf(segments[o], segments[o + 2]), minf(segments[o + 1], segments[o + 3])) - Vector2.ONE * reach
	var hi := Vector2(maxf(segments[o], segments[o + 2]), maxf(segments[o + 1], segments[o + 3])) + Vector2.ONE * reach
	var a := ((lo - corner) / TILE).floor()
	var b := ((hi - corner) / TILE).floor()
	var x0 := clampi(int(a.x), 0, tiles_per_side - 1)
	var y0 := clampi(int(a.y), 0, tiles_per_side - 1)
	var x1 := clampi(int(b.x), 0, tiles_per_side - 1)
	var y1 := clampi(int(b.y), 0, tiles_per_side - 1)
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)


func _build_tiles() -> void:
	var count := tiles_per_side * tiles_per_side
	var offsets := PackedInt32Array()
	offsets.resize(count + 1)
	var ranges: Array[Rect2i] = []
	for i in segment_count():
		var r := _tile_range(i)
		ranges.append(r)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				offsets[y * tiles_per_side + x + 1] += 1
	for t in count:
		offsets[t + 1] += offsets[t]
	var fill := offsets.duplicate()
	var index := PackedInt32Array()
	index.resize(offsets[count])
	for i in ranges.size():
		var r := ranges[i]
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var t := y * tiles_per_side + x
				index[fill[t]] = i
				fill[t] += 1
	tiles = offsets
	tiles.append_array(index)


## The channel whose bank is nearest, relative to its width: "r" (distance /
## half width, < 1 inside the channel), "distance", "half_width", "surface",
## "depth", "flow_dir" (Vector2), "speed" and "wet". Empty if none is near.
func query(x: float, z: float) -> Dictionary:
	var g := ((Vector2(x, z) - corner) / TILE).floor()
	if g.x < 0 or g.y < 0 or g.x >= tiles_per_side or g.y >= tiles_per_side:
		return {}
	var t := int(g.y) * tiles_per_side + int(g.x)
	var base := tiles_per_side * tiles_per_side + 1
	var best := {}
	var best_r := INF
	var p := Vector2(x, z)
	for k in range(tiles[t], tiles[t + 1]):
		var o := tiles[base + k] * SEG_FLOATS
		var a := Vector2(segments[o], segments[o + 1])
		var ab := Vector2(segments[o + 2], segments[o + 3]) - a
		var u := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d := p.distance_to(a + ab * u)
		var hw := lerpf(segments[o + 6], segments[o + 7], u)
		var r := d / hw
		if r < best_r:
			best_r = r
			var v := lerpf(segments[o + 10], segments[o + 11], u)
			best = {"r": r, "distance": d, "half_width": hw, "surface": lerpf(segments[o + 4], segments[o + 5], u),
					"depth": lerpf(segments[o + 8], segments[o + 9], u), "flow_dir": ab.normalized(),
					"speed": maxf(v, 0.0), "wet": v > -0.5}
	return best
