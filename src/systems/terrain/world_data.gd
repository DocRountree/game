class_name WorldData
extends RefCounted
## The generated world, as loaded from res://world/ (written by tools/worldgen,
## in the format world/schema.json describes, which this checks): the height
## map's byte planes, the ground masks, the rivers (RiverData, with their
## RiverNetwork), the river islands, trees, landmasses and where to start.
## Loaded once and shared. Only a file loader: the ground is asked through
## Terrain (HeightmapSource answers from this), the rivers through RiverBody.
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
var rivers: Array[RiverData] = []   ## Downstream order.
var river_network: RiverNetwork
var landmasses: Array = []
## Islands in the rivers: Dictionaries with "x", "z" (middle), "dx", "dz"
## (downstream), "length", "width" (half width at its middle), "top" (m).
var islands: Array = []
var trees := PackedByteArray()      ## 8 bytes per tree (see world/schema.json).

static var _shared: WorldData


## The world, loaded on first use (null if it hasn't been generated).
static func get_world() -> WorldData:
	if _shared == null:
		_shared = WorldData.new()
		if not _shared._load():
			_shared = null
	return _shared


## The format this build reads (world/schema.json).
static func schema() -> Dictionary:
	var s = JSON.parse_string(FileAccess.get_file_as_string(DIR + "schema.json"))
	return s if s is Dictionary else {}


func _load() -> bool:
	var meta = JSON.parse_string(FileAccess.get_file_as_string(DIR + "world.json"))
	if meta == null:
		push_error("No generated world in %s: run tools/worldgen" % DIR)
		return false
	var sch := schema()
	if int(meta.get("version", 0)) != int(sch.get("version", -1)):
		push_error("The world in %s is format %s, this build reads %s: regenerate it with tools/worldgen"
				% [DIR, meta.get("version", "?"), sch.get("version", "?")])
		return false
	for field: String in sch.get("required", []):
		if not meta.has(field):
			push_error("world.json has no \"%s\": regenerate it with tools/worldgen" % field)
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
	islands = meta.islands
	var total := 0
	var s := texels
	while s >= 1:
		total += s * s
		s /= 2
	hi = FileAccess.get_file_as_bytes(DIR + "height_hi.bin").decompress(total, FileAccess.COMPRESSION_DEFLATE)
	lo = FileAccess.get_file_as_bytes(DIR + "height_lo.bin").decompress(total, FileAccess.COMPRESSION_DEFLATE)
	if hi.size() != total or lo.size() != total:
		push_error("World heights are damaged: regenerate them with tools/worldgen")
		return false
	ground = Image.new()
	ground.load_png_from_buffer(FileAccess.get_file_as_bytes(DIR + "ground.png"))
	trees = FileAccess.get_file_as_bytes(DIR + "trees.bin").decompress(int(meta.trees) * 8, FileAccess.COMPRESSION_DEFLATE)
	for r: Dictionary in meta.rivers:
		var pts := PackedVector3Array()
		for p: Array in r.points:
			pts.append(Vector3(p[0], p[1], p[2]))
		var falls: Array[Vector2i] = []
		for c: Array in r.falls:
			falls.append(Vector2i(int(c[0]), int(c[1])))
		rivers.append(RiverData.new(pts, PackedFloat32Array(r.half_width), PackedFloat32Array(r.depth),
				PackedFloat32Array(r.riser), falls, int(r.joins)))
	river_network = RiverNetwork.new(rivers, size)
	return true


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
