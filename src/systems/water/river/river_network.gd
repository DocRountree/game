class_name RiverNetwork
extends RefCounted
## Every river of a world together (WorldData builds it on load): a spatial
## index of their segments in TILE m tiles, so "which channel is here, how
## high is its water, which way does it run" (channel()) is a short search;
## and the map of where their water stands above the sea, for the ocean
## (mask_texture()).

const TILE := 128.0   ## Index tile side (m).
const SEG := 10       ## Floats per segment: a.x, a.z, b.x, b.z, level a, level b, hw a, hw b, speed a, speed b.

var rivers: Array[RiverData] = []
var world_size := 0.0

var _segments := PackedFloat32Array()
var _tiles: Array[PackedInt32Array] = []
var _per_side := 0
var _corner := Vector2.ZERO
var _mask: ImageTexture


func _init(river_list: Array[RiverData], size: float) -> void:
	rivers = river_list
	world_size = size
	_per_side = ceili(size / TILE)
	_corner = -Vector2.ONE * size * 0.5
	_tiles.resize(_per_side * _per_side)
	for t in _tiles.size():
		_tiles[t] = PackedInt32Array()
	for r in rivers:
		var p := r.points
		var hw := r.half_width
		var sp := r.speed
		for k in p.size() - 1:
			if Vector2(p[k].x - p[k + 1].x, p[k].z - p[k + 1].z).length_squared() < 0.01:
				continue
			var i := _segments.size() / SEG
			_segments.append_array([p[k].x, p[k].z, p[k + 1].x, p[k + 1].z, p[k].y, p[k + 1].y, hw[k], hw[k + 1], sp[k], sp[k + 1]])
			var reach := maxf(hw[k], hw[k + 1]) * 2.0 + 4.0
			var lo := ((Vector2(minf(p[k].x, p[k + 1].x), minf(p[k].z, p[k + 1].z)) - Vector2.ONE * reach - _corner) / TILE).floor()
			var hi := ((Vector2(maxf(p[k].x, p[k + 1].x), maxf(p[k].z, p[k + 1].z)) + Vector2.ONE * reach - _corner) / TILE).floor()
			for y in range(clampi(int(lo.y), 0, _per_side - 1), clampi(int(hi.y), 0, _per_side - 1) + 1):
				for x in range(clampi(int(lo.x), 0, _per_side - 1), clampi(int(hi.x), 0, _per_side - 1) + 1):
					_tiles[y * _per_side + x].append(i)


## The channel at a point: "r" (distance / half width from the nearest
## centreline), "surface" (water level, blended over nearby reaches),
## "flow" (Vector2 m/s, fastest mid-channel). Empty away from rivers.
func channel(x: float, z: float) -> Dictionary:
	var g := ((Vector2(x, z) - _corner) / TILE).floor()
	if g.x < 0 or g.y < 0 or g.x >= _per_side or g.y >= _per_side:
		return {}
	var p := Vector2(x, z)
	var best := INF
	var ws := 0.0
	var wl := 0.0
	var flow := Vector2.ZERO
	var wf := 0.0
	for i in _tiles[int(g.y) * _per_side + int(g.x)]:
		var o := i * SEG
		var a := Vector2(_segments[o], _segments[o + 1])
		var ab := Vector2(_segments[o + 2], _segments[o + 3]) - a
		var u := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var r := p.distance_to(a + ab * u) / lerpf(_segments[o + 6], _segments[o + 7], u)
		if r > 2.0:
			continue
		best = minf(best, r)
		var w := exp(-6.0 * r)
		ws += w
		wl += w * lerpf(_segments[o + 4], _segments[o + 5], u)
		wf += w
		flow += w * ab.normalized() * lerpf(_segments[o + 8], _segments[o + 9], u) * (1.0 - 0.5 * minf(r * r, 1.0))
	if ws == 0.0:
		return {}
	return {"r": best, "surface": wl / ws, "flow": flow / wf}


## Every fall in the world, tallest first: [RiverData, FallData] pairs.
func falls_by_height() -> Array:
	var out := []
	for r in rivers:
		for f in r.falls:
			out.append([r, f])
	out.sort_custom(func(a: Array, b: Array) -> bool: return (a[1] as FallData).drop > (b[1] as FallData).drop)
	return out


## Where the rivers' water stands above the sea, for the ocean (which isn't
## drawn under it): an R8 texture of the world at `resolution` texels a side,
## each texel the level of the nearest reach (0..2 m as 0..1; 0 outside the
## rivers); where two rivers' water overlaps, the lower (so a tributary's
## never breaks up the smooth fall of its river's to the sea). Only the
## reaches low enough to have sea-level ground under them count.
func mask_texture(resolution: int) -> ImageTexture:
	if _mask:
		return _mask
	var n := resolution
	var size := world_size
	var cell := size / n
	var data := PackedByteArray()
	data.resize(n * n)
	var near := PackedFloat32Array()
	near.resize(n * n)
	near.fill(INF)
	var owner := PackedInt32Array()
	owner.resize(n * n)
	owner.fill(-1)
	for ri in rivers.size():
		var pts := rivers[ri].points
		var hw := rivers[ri].half_width
		for k in pts.size() - 1:
			if pts[k].y > 12.0:
				continue   # (right down to the sea, so the mask fades out smoothly at the coast)
			var steps := maxi(ceili(Vector2(pts[k + 1].x - pts[k].x, pts[k + 1].z - pts[k].z).length() / 5.0), 1)
			for st in steps:
				var t := float(st) / steps
				var p := pts[k].lerp(pts[k + 1], t)
				var rad := lerpf(hw[k], hw[k + 1], t) * 1.05   # (the water itself, not the shore beside it)
				var v := int(clampf(p.y / 2.0, 0.0, 1.0) * 255.0)
				var cx := (p.x + size * 0.5) / cell
				var cz := (p.z + size * 0.5) / cell
				var rc := rad / cell
				for iz in range(maxi(int(cz - rc), 0), mini(int(cz + rc) + 1, n)):
					for ix in range(maxi(int(cx - rc), 0), mini(int(cx + rc) + 1, n)):
						var dd := Vector2(ix + 0.5 - cx, iz + 0.5 - cz).length()
						var i := iz * n + ix
						if dd > rc:
							continue
						if owner[i] == ri and dd < near[i] or owner[i] == -1 or owner[i] != ri and v < data[i]:
							owner[i] = ri
							near[i] = dd
							data[i] = v
	_mask = ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_R8, data))
	return _mask
