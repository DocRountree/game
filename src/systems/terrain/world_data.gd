class_name WorldData
extends RefCounted
## The generated world (tools/gen_world.py writes it to res://world/): heights,
## ground masks, rivers, trees and where to start. Loaded once and shared.
##
## Heights are 16-bit, stored as two byte planes (high and low), each with its
## whole mip chain, so the GPU reads them as two R8 textures without any
## per-pixel work here. Sample i sits at world -size/2 + i * spacing.

const DIR := "res://world/"

var size := 20480.0                 ## World side (m); the world is +-size/2 around the origin.
var texels := 8192                  ## Height samples per side.
var spacing := 2.5                  ## m between samples.
var h_min := -300.0
var h_max := 1100.0
var h_scale := 0.0                  ## m per 16-bit step.
var hi := PackedByteArray()         ## High bytes, every mip (level 0 first).
var lo := PackedByteArray()
var ground: Image                   ## RGBA: rock, sand, forest density, ambient occlusion.
var spawn := Vector2.ZERO           ## Where the player starts (world x, z).
var boat := Vector2.ZERO            ## Where the boat is moored.
## Rivers: Dictionaries with "points" (PackedVector3Array: x, water level, z),
## "half_width", "depth", "speed" (PackedFloat32Array per point) and "joins"
## (the index of the river it runs into, -1 for the sea). Downstream order.
var rivers: Array[Dictionary] = []
var landmasses: Array = []
var trees := PackedByteArray()      ## 8 bytes per tree: uint16 x, uint16 z, uint16 ground height (as the heights), uint8 height (dm), uint8 spare.

static var _shared: WorldData
var _river_mask: ImageTexture


## The world, loaded on first use (null if it hasn't been generated).
static func get_world() -> WorldData:
	if _shared == null:
		_shared = WorldData.new()
		if not _shared._load():
			_shared = null
	return _shared


func _load() -> bool:
	var meta = JSON.parse_string(FileAccess.get_file_as_string(DIR + "world.json"))
	if meta == null:
		push_error("No generated world in %s: run tools/gen_world.py" % DIR)
		return false
	size = meta.world_size
	texels = int(meta.texels)
	spacing = size / texels
	h_min = meta.h_min
	h_max = meta.h_max
	h_scale = (h_max - h_min) / 65535.0
	spawn = Vector2(meta.spawn[0], meta.spawn[1])
	boat = Vector2(meta.boat[0], meta.boat[1])
	landmasses = meta.landmasses
	var total := 0
	var s := texels
	while s >= 1:
		total += s * s
		s /= 2
	hi = FileAccess.get_file_as_bytes(DIR + "height_hi.bin").decompress(total, FileAccess.COMPRESSION_DEFLATE)
	lo = FileAccess.get_file_as_bytes(DIR + "height_lo.bin").decompress(total, FileAccess.COMPRESSION_DEFLATE)
	if hi.size() != total or lo.size() != total:
		push_error("World heights are damaged: regenerate them with tools/gen_world.py")
		return false
	ground = Image.new()
	ground.load_png_from_buffer(FileAccess.get_file_as_bytes(DIR + "ground.png"))
	var tz := FileAccess.get_file_as_bytes(DIR + "trees.bin")
	trees = tz.decompress(int(meta.get("trees", 0)) * 8, FileAccess.COMPRESSION_DEFLATE)
	for r: Dictionary in meta.rivers:
		var pts := PackedVector3Array()
		for p: Array in r.points:
			pts.append(Vector3(p[0], p[1], p[2]))
		var hw := PackedFloat32Array(r.half_width)
		var depth := PackedFloat32Array(r.depth)
		rivers.append({"points": pts, "half_width": hw, "depth": depth, "speed": _current(pts, hw), "joins": int(r.joins)})
	return true


## Where the rivers' water stands above the sea, for the ocean (which isn't
## drawn under it): an R8 texture of the world at 1/4 the height resolution,
## each texel the level of the nearest reach (0..2 m as 0..1; 0 outside the rivers);
## where two rivers' water overlaps, the lower (so a tributary's never breaks
## up the smooth fall of its river's to the sea).
## Only the reaches low enough to have sea-level ground under them count.
func river_mask() -> ImageTexture:
	if _river_mask:
		return _river_mask
	var n := texels / 4
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
		var r: Dictionary = rivers[ri]
		var pts: PackedVector3Array = r.points
		var hw: PackedFloat32Array = r.half_width
		for k in pts.size() - 1:
			if pts[k].y > 12.0 or pts[k].y < 0.2:
				continue
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
	_river_mask = ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_R8, data))
	return _river_mask


## A river's current (m/s) at each point: faster where the water falls (the
## drop over 80 m of it), bigger rivers a little faster, and smoothed over
## about 120 m, so it never changes abruptly from one point to the next
## (however unevenly the points are spaced).
static func _current(pts: PackedVector3Array, hw: PackedFloat32Array) -> PackedFloat32Array:
	var n := pts.size()
	var arc := PackedFloat32Array([0.0])
	for k in range(1, n):
		arc.append(arc[k - 1] + Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length())
	var raw := PackedFloat32Array()
	var a := 0
	var b := 0
	for k in n:
		while a < k and arc[k] - arc[a] > 40.0:
			a += 1
		while b < n - 1 and arc[b] - arc[k] < 40.0:
			b += 1
		var slope := maxf(pts[a].y - pts[b].y, 0.0) / maxf(arc[b] - arc[a], 1.0)
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
		out.append(sum / (b - a))
	return out


## The 16-bit height sample (ix, iz) of mip level 0, in metres.
func sample(ix: int, iz: int) -> float:
	ix = clampi(ix, 0, texels - 1)
	iz = clampi(iz, 0, texels - 1)
	var i := iz * texels + ix
	return (hi[i] * 256 + lo[i]) * h_scale + h_min


## Ground height (m) at a world point, bilinear between samples (as the
## finest terrain patches draw it). Deep sea outside the world.
func height_at(x: float, z: float) -> float:
	var gx := (x + size * 0.5) / spacing
	var gz := (z + size * 0.5) / spacing
	if gx < 0.0 or gz < 0.0 or gx > texels - 1 or gz > texels - 1:
		return h_min
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	return lerpf(lerpf(sample(ix, iz), sample(ix + 1, iz), fx), lerpf(sample(ix, iz + 1), sample(ix + 1, iz + 1), fx), fz)


## The ground masks at a point: rock, sand, forest density, ambient occlusion (0..1).
func ground_at(x: float, z: float) -> Color:
	var w := ground.get_width()
	var px := clampi(int((x + size * 0.5) / size * w), 0, w - 1)
	var pz := clampi(int((z + size * 0.5) / size * w), 0, w - 1)
	return ground.get_pixel(px, pz)


## The two byte planes as mipmapped R8 textures, for the shaders.
func height_textures() -> Array[ImageTexture]:
	var out: Array[ImageTexture] = []
	for plane in [hi, lo]:
		var img := Image.create_from_data(texels, texels, true, Image.FORMAT_R8, plane)
		out.append(ImageTexture.create_from_image(img))
	return out


func tree_count() -> int:
	return trees.size() / 8


## Tree i: world x, ground height and z.
func tree(i: int) -> Vector3:
	var o := i * 8
	return Vector3(trees.decode_u16(o) / 65535.0 * size - size * 0.5, trees.decode_u16(o + 4) * h_scale + h_min,
			trees.decode_u16(o + 2) / 65535.0 * size - size * 0.5)


## Tree i's height (m).
func tree_height(i: int) -> float:
	return trees[i * 8 + 6] / 10.0
