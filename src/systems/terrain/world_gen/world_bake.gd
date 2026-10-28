class_name WorldBake
extends RefCounted
## Builds the world from its hand-painted maps (res://world/, see
## world/README.md), once, and caches the result. Pure CPU and deterministic.
##
## world/layout.json places each landmass's maps in the 30 km world: a height
## map (16-bit grayscale, black = sea) and, for the main island, a river map
## (white strokes); one world-wide biome map (flat colours, see
## WorldMaps.BIOME_TINT) says what each place will be.
##
## 1. Land: every landmass's height map is sampled onto one world grid.
## 2. Seafloor: shelves falling away from every coast; shallow sandy banks
##    among an archipelago's islands, steep drops around volcanoes.
## 3. Rivers: water is routed downhill over the land, preferring the painted
##    strokes, so each stroke becomes a river that always runs down to the
##    sea; widths grow with the land draining into them.
## 4. Biomes: the painted world map; each landmass but the main island, with
##    the water nearest it, is its own biome where nothing else is painted.
## The fine detail (the erosion filter's gullies, mesa cliffs, river
## valleys) is added on the GPU by Terrain.

const VERSION := 32
const LAYOUT := "res://world/layout.json"
const MAPS := "res://world/maps/"
const YEAR := 31557600.0

enum { RIVER, OXBOW, SCAR }   ## River kinds (only RIVER is made now).

const KINDS := ["continent", "island", "archipelago", "volcanic"]

var n: int
var cell: float
var size: float
var config: WorldConfig
var progress := 0.0               ## 0..1, safe to read from another thread.
var stage := ""
var debug_timing := false

var m: WorldMaps
var layout := {}

var _is_land := PackedByteArray()
var _dist := PackedFloat32Array()      # land: to the sea; sea: to the land (m)
var _kind := PackedByteArray()         # per cell: 1 + the kind of the landmass map covering it (0: none)
var _near := PackedByteArray()         # sea cells: owner (landmass + 1) of the nearest land
var _river_mask := PackedFloat32Array()
var _nb := PackedInt32Array()
var _t0 := 0


## The world's size comes from world/layout.json.
func _init(world_config: WorldConfig, cells := 2048) -> void:
	config = world_config
	n = cells
	layout = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	size = layout.get("world_size", 300000.0)
	cell = size / cells
	_nb = PackedInt32Array([-n - 1, -n, -n + 1, -1, 1, n - 1, n, n + 1])


func run() -> WorldMaps:
	m = WorldMaps.new()
	m.setup(n, size)
	m.seed = config.world_seed
	m.version = VERSION
	_step("land", 0.05)
	_land()
	_step("coastlines", 0.3)
	_coast_distance()
	_step("seafloor", 0.45)
	_seafloor()
	_step("rivers", 0.6)
	_rivers()
	_step("biomes", 0.85)
	_biomes()
	_materials()
	_shift_to_spawn()
	_step("done", 1.0)
	return m


func _step(name: String, at: float) -> void:
	if debug_timing and stage != "":
		print("  %s took %d ms" % [stage, Time.get_ticks_msec() - _t0])
	_t0 = Time.get_ticks_msec()
	stage = name
	progress = at


func _cx(i: int) -> float:
	return (i % n + 0.5) * cell - size * 0.5


func _cz(i: int) -> float:
	return (i / n + 0.5) * cell - size * 0.5


# The grid cells a landmass's maps cover, as [x0, y0, x1, y1].
func _span(c: Vector2, side: float) -> Array:
	var g0 := ((c - Vector2.ONE * side * 0.5 + Vector2.ONE * size * 0.5) / cell).floor()
	var g1 := ((c + Vector2.ONE * side * 0.5 + Vector2.ONE * size * 0.5) / cell).ceil()
	return [clampi(int(g0.x), 0, n - 1), clampi(int(g0.y), 0, n - 1), clampi(int(g1.x), 0, n - 1), clampi(int(g1.y), 0, n - 1)]


# --- 1. land --------------------------------------------------------------------------------

func _land() -> void:
	var count := n * n
	var h := m.height
	h.fill(-1e9)
	_is_land.resize(count)
	_kind.resize(count)
	_river_mask.resize(count)
	var sea_value: float = layout.get("sea_value", 0.02)
	for li in layout.landmasses.size():
		var lm: Dictionary = layout.landmasses[li]
		var kind := KINDS.find(lm.get("kind", "island"))
		var c := Vector2(lm.center[0], lm.center[1])
		var side: float = lm.size
		var peak: float = lm.get("peak", 500.0)
		var hm := MapImage.open(MAPS + lm.height)
		var rv: MapImage = MapImage.open(MAPS + lm.rivers) if lm.has("rivers") else null
		m.landmasses.append({"kind": kind, "name": lm.name, "center": c, "radius": side * 0.5})
		var sp := _span(c, side)
		for y in range(sp[1], sp[3] + 1):
			for x in range(sp[0], sp[2] + 1):
				var i := y * n + x
				var u := (_cx(i) - c.x) / side + 0.5
				var v := (_cz(i) - c.y) / side + 0.5
				if u < 0.0 or v < 0.0 or u >= 1.0 or v >= 1.0:
					continue
				if _kind[i] == 0:
					_kind[i] = kind + 1
				var val := hm.sample(u, v)
				if val <= sea_value:
					continue
				var hh := 0.3 + (val - sea_value) / (1.0 - sea_value) * peak
				if hh > h[i]:
					h[i] = hh
					m.owner[i] = li + 1
					_kind[i] = kind + 1
					if rv:
						_river_mask[i] = rv.sample(u, v)
		progress = 0.05 + 0.25 * (li + 1) / layout.landmasses.size()
	for i in count:
		# land stays off the world's edge
		var x := i % n
		var y := i / n
		var land := h[i] > 0.0 and x > 2 and y > 2 and x < n - 3 and y < n - 3
		_is_land[i] = 1 if land else 0
		m.water_kind[i] = WorldMaps.WaterKind.LAND if land else WorldMaps.WaterKind.OCEAN
		if not land:
			m.owner[i] = 0


# Chamfer distance: land cells to the nearest sea cell, sea cells to the
# nearest land (and which landmass that is).
func _coast_distance() -> void:
	var count := n * n
	_dist.resize(count)
	_dist.fill(1e9)
	_near.resize(count)
	var isl := _is_land
	var dist := _dist
	var near := _near
	for i in range(n + 1, count - n - 1):
		var land := isl[i]
		for k in 8:
			var j := i + _nb[k]
			if isl[j] != land:
				dist[i] = cell * 0.5
				near[i] = m.owner[j] if land == 0 else m.owner[i]
				break
	var d1 := cell
	var d2 := cell * sqrt(2.0)
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			var land := isl[i]
			var v := dist[i]
			var nr := near[i]
			var j := i - n - 1
			if isl[j] == land and dist[j] + d2 < v: v = dist[j] + d2; nr = near[j]
			j = i - n
			if isl[j] == land and dist[j] + d1 < v: v = dist[j] + d1; nr = near[j]
			j = i - n + 1
			if isl[j] == land and dist[j] + d2 < v: v = dist[j] + d2; nr = near[j]
			j = i - 1
			if isl[j] == land and dist[j] + d1 < v: v = dist[j] + d1; nr = near[j]
			dist[i] = v
			near[i] = nr
	for y in range(n - 2, 0, -1):
		for x in range(n - 2, 0, -1):
			var i := y * n + x
			var land := isl[i]
			var v := dist[i]
			var nr := near[i]
			var j := i + n + 1
			if isl[j] == land and dist[j] + d2 < v: v = dist[j] + d2; nr = near[j]
			j = i + n
			if isl[j] == land and dist[j] + d1 < v: v = dist[j] + d1; nr = near[j]
			j = i + n - 1
			if isl[j] == land and dist[j] + d2 < v: v = dist[j] + d2; nr = near[j]
			j = i + 1
			if isl[j] == land and dist[j] + d1 < v: v = dist[j] + d1; nr = near[j]
			dist[i] = v
			near[i] = nr


# --- 2. seafloor -----------------------------------------------------------------------------

func _seafloor() -> void:
	var h := m.height
	var bumps := FastNoiseLite.new()
	bumps.seed = config.seed_for("seafloor")
	bumps.fractal_octaves = 4
	# the whole grid at once (natively; 8 bits is plenty for bumps)
	bumps.frequency = cell / 9000.0
	bumps.offset = Vector3(-size * 0.5 / cell + 0.5, -size * 0.5 / cell + 0.5, 0.0)
	var bump := bumps.get_image(n, n, false, false, false).get_data()
	for i in n * n:
		if _is_land[i] == 1:
			continue
		var b := bump[i] / 127.5 - 1.0
		# (the distance warped by the noise, so shelves and banks wander
		# instead of tracing the distance metric's octagons)
		var d := maxf(_dist[i] * (1.0 + 0.3 * b) + 2500.0 * b * smoothstep(0.0, 3000.0, _dist[i]), 0.0)
		# shelf, slope, deep sea
		var depth := 1.0 + 40.0 * (1.0 - exp(-d / 3000.0)) + 1500.0 * smoothstep(6000.0, 30000.0, d)
		depth *= 1.0 + 0.25 * b
		var nearest := KINDS.find(layout.landmasses[_near[i] - 1].get("kind", "island")) if _near[i] > 0 else -1
		match nearest:
			2:   # among an archipelago's islands: a shallow sandy bank
				depth = lerpf(depth, minf(depth, 2.0 + 7.0 * (b * 0.5 + 0.5) + d * 0.0015), 1.0 - smoothstep(4000.0, 9000.0, d))
			3:   # volcanoes plunge steeply into deep water
				depth = lerpf(depth, maxf(depth, 1.0 + 160.0 * (1.0 - exp(-d / 1500.0)) + 1500.0 * smoothstep(3000.0, 15000.0, d)), 1.0 - smoothstep(10000.0, 20000.0, d))
		h[i] = -maxf(depth, 0.5)


# --- 3. rivers --------------------------------------------------------------------------------

var _recv := PackedInt32Array()
var _order := PackedInt32Array()
var _area := PackedFloat32Array()


# Water routed by a priority flood up from the coast (Barnes et al. 2014),
# lowest first, with the painted strokes sunk so the water finds them; each
# cell drains into the cell that reached it. Then each stroke is traced down
# to the sea (or to the river it joins) as a smooth centreline.
func _rivers() -> void:
	var count := n * n
	var h := m.height
	_recv.resize(count)
	_recv.fill(-1)
	_area.resize(count)
	var key := PackedFloat32Array()
	key.resize(count)
	for i in count:
		key[i] = h[i] - (3000.0 if _river_mask[i] > 0.3 else 0.0)   # (below everything: the strokes fill from their mouth first)
	var seen := PackedByteArray()
	seen.resize(count)
	var heap := Heap.new()
	# each river system reaches the sea only at its mouth (layout
	# "river_mouths"): elsewhere a stroke passing close to the coast is not an
	# outlet, so all its water drains through the one mouth
	var mouths := PackedInt32Array()
	for lm: Dictionary in layout.landmasses:
		for mw: Array in lm.get("river_mouths", []):
			var best := -1
			var best_d := INF
			var g := ((Vector2(mw[0], mw[1]) + Vector2.ONE * size * 0.5) / cell).floor()
			var r := maxi(ceili(600.0 / cell), 4)
			for y in range(maxi(int(g.y) - r, 1), mini(int(g.y) + r, n - 2) + 1):
				for x in range(maxi(int(g.x) - r, 1), mini(int(g.x) + r, n - 2) + 1):
					var i := y * n + x
					if _is_land[i] == 1 and _river_mask[i] > 0.3 and _dist[i] < cell * 1.5:
						var d := Vector2(_cx(i) - mw[0], _cz(i) - mw[1]).length()
						if d < best_d:
							best_d = d
							best = i
			if best >= 0:
				mouths.append(best)
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			if _is_land[i] == 0:
				continue
			if _river_mask[i] > 0.3 and not mouths.is_empty() and not mouths.has(i):
				continue
			for k in 8:
				if _is_land[i + _nb[k]] == 0:
					_recv[i] = i + _nb[k]
					seen[i] = 1
					heap.push(key[i], i)
					break
	while not heap.empty():
		var i := heap.pop()
		_order.append(i)
		var gx := i % n
		var gy := i / n
		if gx < 1 or gy < 1 or gx > n - 2 or gy > n - 2:
			continue
		for k in 8:
			var j := i + _nb[k]
			if _is_land[j] == 0 or seen[j] == 1:
				continue
			seen[j] = 1
			key[j] = maxf(key[j], key[i] + 0.01)
			_recv[j] = i
			heap.push(key[j], j)
	_area.fill(cell * cell)
	for k in range(_order.size() - 1, -1, -1):
		var i := _order[k]
		var j := _recv[i]
		if j >= 0 and _is_land[j] == 1:
			_area[j] += _area[i]
	# trace every stroke from its heads down, longest first, so main stems are
	# traced before the little bits that join them
	var on := PackedByteArray()
	on.resize(count)
	var has_donor := PackedByteArray()
	has_donor.resize(count)
	for i in count:
		if _is_land[i] == 1 and _river_mask[i] > 0.3:
			on[i] = 1
	for i in count:
		if on[i] == 1 and _recv[i] >= 0 and on[_recv[i]] == 1:
			has_donor[_recv[i]] = 1
	var heads := []
	for i in count:
		if on[i] == 1 and has_donor[i] == 0:
			heads.append(Vector2i(_path_len(i, on), i))
	heads.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x > b.x)
	var river_of := PackedInt32Array()
	river_of.resize(count)
	river_of.fill(-1)
	for head: Vector2i in heads:
		var cells := PackedInt32Array()
		var c := head.y
		var joins := -1
		while c >= 0:
			cells.append(c)
			# (touching a river already traced, even diagonally alongside it,
			# is joining it: strokes are a couple of cells wide)
			var touch := river_of[c]
			if touch < 0 and _is_land[c] == 1:
				for k in 8:
					if river_of[c + _nb[k]] >= 0:
						touch = river_of[c + _nb[k]]
						break
			if touch >= 0:
				joins = touch
				break
			if _is_land[c] == 0:
				break
			c = _recv[c]
		if cells.size() < 10:
			continue
		for q in cells.size() - (1 if joins >= 0 else 0):
			river_of[cells[q]] = m.rivers.size()
		var river := _make_river(cells)
		river.joins = joins
		m.rivers.append(river)
	# each tributary ends exactly on the river it joins
	for river in m.rivers:
		var j: int = river.joins
		if j < 0:
			continue
		var pts: PackedVector3Array = river.points
		var main: PackedVector3Array = m.rivers[j].points
		var end := pts[pts.size() - 1]
		var best := 0
		var best_d := INF
		for k in main.size():
			var d := Vector2(main[k].x - end.x, main[k].z - end.z).length_squared()
			if d < best_d:
				best_d = d
				best = k
		pts[pts.size() - 1] = Vector3(main[best].x, minf(main[best].y, pts[pts.size() - 2].y), main[best].z)
		river.points = pts
	for river in m.rivers:
		_fill(river)


# How far the water from cell i runs along the strokes.
func _path_len(i: int, on: PackedByteArray) -> int:
	var k := 0
	while i >= 0 and on[i] == 1 and k < 100000:
		i = _recv[i]
		k += 1
	return k


# A river from its cells: smoothed into a flowing line, the water surface the
# ground under it (only ever falling downstream), sized by the land draining
# into it.
func _make_river(cells: PackedInt32Array) -> Dictionary:
	var pts := PackedVector2Array()
	var el := PackedFloat32Array()
	var ar := PackedFloat32Array()
	for c in cells:
		pts.append(Vector2(_cx(c), _cz(c)))
		el.append(maxf(m.height[c], 0.0))
		ar.append(_area[c] if _is_land[c] == 1 or ar.is_empty() else ar[ar.size() - 1])
	# the cell-to-cell zigzag smoothed out first (ends fixed), then the
	# corners cut into a flowing line
	for _it in 8:
		var prev := pts.duplicate()
		for k in range(1, pts.size() - 1):
			pts[k] = (prev[k - 1] + prev[k] * 2.0 + prev[k + 1]) * 0.25
	for _it in 3:   # corner cutting, ends fixed
		var np := PackedVector2Array([pts[0]])
		var ne := PackedFloat32Array([el[0]])
		var na := PackedFloat32Array([ar[0]])
		for k in pts.size() - 1:
			for f: float in [0.25, 0.75]:
				if (k == 0 and f == 0.25) or (k == pts.size() - 2 and f == 0.75):
					continue
				np.append(pts[k].lerp(pts[k + 1], f))
				ne.append(lerpf(el[k], el[k + 1], f))
				na.append(lerpf(ar[k], ar[k + 1], f))
		np.append(pts[pts.size() - 1])
		ne.append(el[el.size() - 1])
		na.append(ar[ar.size() - 1])
		pts = np
		el = ne
		ar = na
	var count := pts.size()
	# the water surface: the downhill profile closest to the ground along the
	# channel (isotonic regression, pool adjacent violators), so it neither
	# perches above the ground nor sinks far below it; the terrain then
	# shapes the channel to it, cutting where the ground is higher and
	# building banks where it is lower
	var eased := _downhill_fit(el)
	var p3 := PackedVector3Array()
	var hw := PackedFloat32Array()
	var depth := PackedFloat32Array()
	var speed := PackedFloat32Array()
	var flow := PackedFloat32Array()
	var wet := PackedByteArray()
	for k in count:
		p3.append(Vector3(pts[k].x, eased[k], pts[k].y))
		var km2 := ar[k] / 1e6
		var q := ar[k] * 0.4 / YEAR   # runoff: ~0.4 m of each year's rain
		hw.append(clampf(4.0 + 2.2 * sqrt(km2), 4.0, 110.0))
		depth.append(clampf(0.6 + 0.12 * sqrt(km2), 0.6, 6.0))
		var lo := maxi(k - 3, 0)
		var hi := mini(k + 3, count - 1)
		var run := maxf(pts[lo].distance_to(pts[hi]), 1.0)
		speed.append(clampf(0.8 + 0.08 * sqrt(q) + 8.0 * sqrt(maxf(eased[lo] - eased[hi], 0.0) / run), 0.8, 4.5))
		flow.append(q)
		wet.append(1)
	return {"points": p3, "half_width": hw, "depth": depth, "speed": speed, "flow": flow,
			"wet": wet, "kind": RIVER, "joins": -1}


# The non-increasing sequence closest (least squares) to v: pool adjacent
# violators, then lightly smoothed (only ever lowering) so its corners are
# ramps.
static func _downhill_fit(v: PackedFloat32Array) -> PackedFloat32Array:
	var sums := PackedFloat32Array()
	var counts := PackedInt32Array()
	for x in v:
		sums.append(x)
		counts.append(1)
		while sums.size() > 1 and sums[sums.size() - 1] / counts[counts.size() - 1] > sums[sums.size() - 2] / counts[counts.size() - 2]:
			sums[sums.size() - 2] += sums[sums.size() - 1]
			counts[counts.size() - 2] += counts[counts.size() - 1]
			sums.resize(sums.size() - 1)
			counts.resize(counts.size() - 1)
	var out := PackedFloat32Array()
	for b in sums.size():
		for _q in counts[b]:
			out.append(sums[b] / counts[b])
	var count := out.size()
	var smooth := out.duplicate()
	for k in count:
		var sum := 0.0
		var cnt := 0
		for q in range(maxi(k - 8, 0), mini(k + 8, count - 1) + 1):
			sum += out[q]
			cnt += 1
		smooth[k] = sum / cnt
	for k in range(1, count):
		smooth[k] = minf(smooth[k], smooth[k - 1])
	return smooth


# Water thins in from a trickle where a river starts, and every channel
# narrows toward its head.
func _fill(river: Dictionary) -> void:
	var pts: PackedVector3Array = river.points
	var hw: PackedFloat32Array = river.half_width
	var arc := 0.0
	var fill := PackedFloat32Array()
	for k in pts.size():
		if k > 0:
			arc += Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length()
		fill.append(smoothstep(0.0, 1500.0, arc))
		hw[k] *= lerpf(0.5, 1.0, smoothstep(0.0, 1500.0, arc))
	river.fill = fill
	river.half_width = hw


# --- 4. biomes and ground -------------------------------------------------------------------

func _biomes() -> void:
	m.biome.fill(WorldMaps.Biome.NONE)
	# each island group, and the water nearest it, is its own biome...
	var own := [WorldMaps.Biome.NONE, WorldMaps.Biome.ISLAND, WorldMaps.Biome.ARCHIPELAGO, WorldMaps.Biome.VOLCANIC]
	for i in n * n:
		var o := m.owner[i] if _is_land[i] == 1 else (_near[i] if _dist[i] < 4000.0 else 0)
		if o > 0:
			m.biome[i] = own[KINDS.find(layout.landmasses[o - 1].get("kind", "island"))]
	# ...and the painted map says the rest (over the island groups' water
	# too, but not their land)
	if not layout.has("biomes"):
		return
	# (resampled to the grid natively, and each distinct colour looked up once)
	var img := Image.new()
	img.load_png_from_buffer(FileAccess.get_file_as_bytes(MAPS + layout.biomes))
	img.convert(Image.FORMAT_RGB8)
	img.resize(n, n, Image.INTERPOLATE_NEAREST)
	var rgb := img.get_data()
	var lookup := {}
	for i in n * n:
		var key := (rgb[i * 3] << 16) | (rgb[i * 3 + 1] << 8) | rgb[i * 3 + 2]
		if key == 0:
			continue
		if not lookup.has(key):
			lookup[key] = WorldMaps.biome_of_color(Color8(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]))
		var b: int = lookup[key]
		if b == WorldMaps.Biome.NONE:
			continue
		if _is_land[i] == 1 and m.owner[i] > 0 and KINDS.find(layout.landmasses[m.owner[i] - 1].get("kind", "island")) != 0:
			continue
		m.biome[i] = b


func _materials() -> void:
	for i in n * n:
		if _is_land[i] == 0:
			m.material[i] = WorldMaps.Ground.SAND
			continue
		var mat := WorldMaps.Ground.DIRT
		match _kind[i] - 1:
			2: mat = WorldMaps.Ground.SAND
			3: mat = WorldMaps.Ground.ROCK
		if m.height[i] < 2.5 and _dist[i] < 120.0:
			mat = WorldMaps.Ground.SAND   # beaches
		m.material[i] = mat


# Move everything so the spawn point (layout "spawn") is the world origin.
func _shift_to_spawn() -> void:
	var spawn := Vector2(layout.spawn[0], layout.spawn[1]) if layout.has("spawn") else Vector2.ZERO
	m.center = -spawn
	for lm in m.landmasses:
		lm.center -= spawn
	var shift := Vector3(spawn.x, 0.0, spawn.y)
	for river in m.rivers:
		var pts: PackedVector3Array = river.points
		for k in pts.size():
			pts[k] -= shift
		river.points = pts


# A binary min-heap of cell ids by key.
class Heap:
	var keys := PackedFloat32Array()
	var vals := PackedInt32Array()

	func empty() -> bool:
		return vals.is_empty()

	func push(key: float, val: int) -> void:
		keys.append(key)
		vals.append(val)
		var i := vals.size() - 1
		while i > 0:
			var p := (i - 1) / 2
			if keys[p] <= keys[i]:
				break
			_swap(i, p)
			i = p

	func pop() -> int:
		var top := vals[0]
		var last := vals.size() - 1
		_swap(0, last)
		keys.resize(last)
		vals.resize(last)
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var s := i
			if l < last and keys[l] < keys[s]:
				s = l
			if r < last and keys[r] < keys[s]:
				s = r
			if s == i:
				break
			_swap(i, s)
			i = s
		return top

	func _swap(a: int, b: int) -> void:
		var tk := keys[a]
		keys[a] = keys[b]
		keys[b] = tk
		var tv := vals[a]
		vals[a] = vals[b]
		vals[b] = tv
