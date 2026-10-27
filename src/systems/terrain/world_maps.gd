class_name WorldMaps
extends RefCounted
## Everything WorldBake works out for a world, on a square grid over the
## world's XZ plane centred on the origin: terrain height, lakes, rivers,
## climate and ground material. Baked once per (seed, generator version) and
## cached on disk; Terrain, the water bodies and the map read it.
##
## Cell (x, y) covers world x in [x * cell - size / 2, (x + 1) * cell - size / 2),
## likewise z with y. Values are stored at cell centres.

enum WaterKind { LAND, OCEAN, LAKE, DRY_LAKE }
enum Ground { SAND, DIRT, ROCK, LAKEBED }

const NO_WATER := -100000.0
const FILE_MAGIC := "WMAP"

var n := 0                         ## Cells per side.
var size := 0.0                    ## World side (m).
var cell := 0.0                    ## Cell side (m).
var seed := 0
var version := 0

var height := PackedFloat32Array()       ## Terrain height (m), sea level 0.
var water_level := PackedFloat32Array()  ## Lake surface (m), spread a few cells past the shore; NO_WATER elsewhere.
var water_kind := PackedByteArray()      ## WaterKind.
var material := PackedByteArray()        ## Ground.
var owner := PackedByteArray()           ## Landmass id + 1; 0 for open sea.
var temperature := PackedFloat32Array()  ## Mean air temperature (C).
var rainfall := PackedFloat32Array()     ## Precipitation (m / year).
## River field, 4 floats per cell: offset x, offset z from the cell centre to
## the nearest point on a river's centreline, the water surface height there,
## and the half width (0 = no river near this cell).
var river_a := PackedFloat32Array()
## 4 floats per cell: flow direction x, z at that nearest point, the depth at
## the centre of the channel, and 1 if water flows there now (0 = dry bed).
var river_b := PackedFloat32Array()

## Rivers as centrelines: each a Dictionary with "points" (PackedVector3Array:
## x, water surface height, z), "half_width", "depth", "flow" (m^3/s) and
## "wet" (PackedByteArray) per point. Downstream order.
var rivers: Array[Dictionary] = []
## Lakes: Dictionaries with "center" (Vector2), "level" (current surface),
## "full_level", "endorheic" (no outlet), "dry", "area" (m^2), "rect" (Rect2
## in world metres) and "inflows" (river count feeding it, wet or dry).
var lakes: Array[Dictionary] = []
## Landmasses as plain data: "kind", "center", "radius".
var landmasses: Array[Dictionary] = []


func setup(cells: int, world_size: float) -> void:
	n = cells
	size = world_size
	cell = world_size / cells
	var count := cells * cells
	for arr: PackedFloat32Array in [height, temperature, rainfall]:
		arr.resize(count)
		arr.fill(0.0)
	water_level.resize(count)
	water_level.fill(NO_WATER)
	for arr: PackedByteArray in [water_kind, material, owner]:
		arr.resize(count)
		arr.fill(0)
	river_a.resize(count * 4)
	river_a.fill(0.0)
	river_b.resize(count * 4)
	river_b.fill(0.0)


# --- queries -------------------------------------------------------------------

## Cell-space coordinates of a world point (cell centres at integers).
func to_grid(x: float, z: float) -> Vector2:
	return Vector2((x + size * 0.5) / cell - 0.5, (z + size * 0.5) / cell - 0.5)


func to_world(gx: float, gy: float) -> Vector2:
	return Vector2((gx + 0.5) * cell - size * 0.5, (gy + 0.5) * cell - size * 0.5)


func index_at(x: float, z: float) -> int:
	var g := to_grid(x, z)
	var ix := clampi(roundi(g.x), 0, n - 1)
	var iy := clampi(roundi(g.y), 0, n - 1)
	return iy * n + ix


func _bilinear(arr: PackedFloat32Array, x: float, z: float) -> float:
	var g := to_grid(x, z)
	var gx := clampf(g.x, 0.0, n - 1.001)
	var gy := clampf(g.y, 0.0, n - 1.001)
	var x0 := int(gx)
	var y0 := int(gy)
	var fx := gx - x0
	var fy := gy - y0
	var i := y0 * n + x0
	var a := lerpf(arr[i], arr[i + 1], fx)
	var b := lerpf(arr[i + n], arr[i + n + 1], fx)
	return lerpf(a, b, fy)


## Baked terrain height (m) at a world point, without the fine detail Terrain adds.
func height_at(x: float, z: float) -> float:
	return _bilinear(height, x, z)


## Lake surface height at a point, or NO_WATER. Water is there only where the
## terrain is below it.
func lake_level_at(x: float, z: float) -> float:
	var i := index_at(x, z)
	return water_level[i]


## The river nearest a point: Dictionary with "distance" (to the centreline),
## "half_width", "surface", "depth", "flow_dir" (Vector2), "wet"; empty if none near.
func river_at(x: float, z: float) -> Dictionary:
	var i := index_at(x, z)
	var hw := river_a[i * 4 + 3]
	if hw <= 0.0:
		return {}
	var c := to_world(i % n, i / n)
	var cx := c.x + river_a[i * 4]
	var cz := c.y + river_a[i * 4 + 1]
	return {"distance": Vector2(x - cx, z - cz).length(), "half_width": hw,
			"surface": river_a[i * 4 + 2], "depth": river_b[i * 4 + 2],
			"flow_dir": Vector2(river_b[i * 4], river_b[i * 4 + 1]), "wet": river_b[i * 4 + 3] > 0.5}


# --- persistence -----------------------------------------------------------------

func save(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(FILE_MAGIC.to_ascii_buffer())
	f.store_32(version)
	f.store_32(n)
	f.store_double(size)
	f.store_64(seed)
	for arr: PackedFloat32Array in [height, water_level, temperature, rainfall, river_a, river_b]:
		f.store_buffer(arr.to_byte_array())
	for arr: PackedByteArray in [water_kind, material, owner]:
		f.store_buffer(arr)
	f.store_var({"rivers": rivers, "lakes": lakes, "landmasses": landmasses})
	f.close()
	return OK


static func load_from(path: String, expect_version: int) -> WorldMaps:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null or f.get_buffer(4).get_string_from_ascii() != FILE_MAGIC:
		return null
	var m := WorldMaps.new()
	m.version = f.get_32()
	if m.version != expect_version:
		return null
	var cells := f.get_32()
	var world_size := f.get_double()
	m.setup(cells, world_size)
	m.seed = f.get_64()
	var count := cells * cells
	m.height = f.get_buffer(count * 4).to_float32_array()
	m.water_level = f.get_buffer(count * 4).to_float32_array()
	m.temperature = f.get_buffer(count * 4).to_float32_array()
	m.rainfall = f.get_buffer(count * 4).to_float32_array()
	m.river_a = f.get_buffer(count * 16).to_float32_array()
	m.river_b = f.get_buffer(count * 16).to_float32_array()
	m.water_kind = f.get_buffer(count)
	m.material = f.get_buffer(count)
	m.owner = f.get_buffer(count)
	var extra: Dictionary = f.get_var()
	m.rivers.assign(extra.get("rivers", []))
	m.lakes.assign(extra.get("lakes", []))
	m.landmasses.assign(extra.get("landmasses", []))
	if m.height.size() != count or m.river_b.size() != count * 4:
		return null
	return m


# --- debug picture -----------------------------------------------------------------

## A shaded map: sea by depth, land by material and height, lakes, wet rivers
## blue and dry riverbeds tan.
func to_image(px := 512) -> Image:
	var img := Image.create(px, px, false, Image.FORMAT_RGB8)
	var step := float(n) / px
	for py in px:
		for qx in px:
			var gx := mini(int((qx + 0.5) * step), n - 1)
			var gy := mini(int((py + 0.5) * step), n - 1)
			var i := gy * n + gx
			var h := height[i]
			var c: Color
			if water_level[i] > NO_WATER and h < water_level[i]:
				c = Color(0.15, 0.4, 0.6)
			elif h < 0.0:
				c = Color(0.05, 0.15, 0.35).lerp(Color(0.25, 0.55, 0.65), clampf(1.0 + h / 60.0, 0.0, 1.0))
			else:
				match material[i]:
					Ground.SAND: c = Color(0.85, 0.78, 0.55)
					Ground.ROCK: c = Color(0.35, 0.33, 0.32)
					Ground.LAKEBED: c = Color(0.7, 0.62, 0.5)
					_: c = Color(0.5, 0.38, 0.25)
				c = c.lerp(Color.WHITE, clampf(h / 2500.0, 0.0, 0.6))
				# relief shading from the slope toward the north-west
				var e := height[mini(i + 1 + n, n * n - 1)] - h
				c = c.darkened(clampf(e / (cell * 1.5), -0.3, 0.4))
			var hw := river_a[i * 4 + 3]
			if hw > 0.0:
				var off := Vector2(river_a[i * 4], river_a[i * 4 + 1]).length()
				if off < maxf(hw, step * cell * 0.5):
					c = Color(0.2, 0.45, 0.9) if river_b[i * 4 + 3] > 0.5 else Color(0.8, 0.68, 0.45)
			img.set_pixel(qx, py, c)
	return img
