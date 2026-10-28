class_name WorldBake
extends RefCounted
## Bakes a world from its seed, once, when the world is created. Pure CPU and
## deterministic: the same seed and VERSION give the same world on any machine.
##
## 1. Layout: WorldLayout places the landmasses; each gives a land shape and
##    an uplift rate (how fast the ground rises).
## 2. Rivers first, then the land (RiverGraph, after Génevaux et al. 2013):
##    a drainage network grows inland from river mouths along every coast;
##    channel elevations follow from stream-power erosion (slope = uplift /
##    sqrt(drained area)), and every point of land takes the elevation of
##    its nearest stream plus a hillslope, with flat floodplains along big
##    gentle rivers. So every river lies exactly on its valley floor.
## 3. Seafloor: sandy shelves falling to the deep sea.
## 4. Lakes: chosen on river valleys and dammed behind a rock sill, so every
##    lake is fed by a river (wet or dry). Some have no outlet (terminal lakes).
## 5. Climate: temperature from height; rain from moist sea wind rising over
##    the land, with rain shadows behind mountains.
## 6. Water today: runoff accumulated down the valleys. Channels were carved
##    by a wetter past, so where today's flow runs out the riverbed is dry.
##    Lakes fill to their sills or shrink until evaporation matches inflow.
## 7. Rivers: the streams big enough to be rivers, sized from today's flow;
##    on floodplains they migrate into meanders (MeanderSim), cutting off
##    oxbow lakes and leaving meander scars.

const VERSION := 19
const YEAR := 31557600.0          ## Seconds per year (rain is in m / year).

var n: int
var cell: float
var size: float
var config: WorldConfig
var progress := 0.0               ## 0..1, safe to read from another thread.
var stage := ""

var m: WorldMaps
var landmasses: Array[Landmass] = []

var _uplift := PackedFloat32Array()
var _shape := PackedFloat32Array()
var _dist := PackedFloat32Array()      # land: to the sea; sea: to the land (m)
var _recv := PackedInt32Array()        # downhill neighbour (-1 none)
var _order := PackedInt32Array()       # land cells, receivers before donors
var _area := PackedFloat32Array()      # drained area (m^2)
var _lake_id := PackedInt32Array()     # lake index + 1 per cell
var _graph: RiverGraph
var _is_land := PackedByteArray()      # 1 on land (lakes included)
var _arid := PackedFloat32Array()      # per cell: its landmass's aridity
var _mark := PackedByteArray()         # scratch flags
var _regions: Array[PackedInt32Array] = []   # cells of each lake

var _nb := PackedInt32Array()          # neighbour index offsets
var _nd := PackedFloat32Array()        # neighbour distances


func _init(world_config: WorldConfig, cells := 1024, world_size := 49152.0) -> void:
	config = world_config
	n = cells
	size = world_size
	cell = world_size / cells
	_nb = PackedInt32Array([-n - 1, -n, -n + 1, -1, 1, n - 1, n, n + 1])
	var d := sqrt(2.0) * cell
	_nd = PackedFloat32Array([d, cell, d, cell, cell, d, cell, d])


func run() -> WorldMaps:
	m = WorldMaps.new()
	m.setup(n, size)
	m.seed = config.world_seed
	m.version = VERSION
	_step("layout", 0.0)
	landmasses = WorldLayout.generate(config)
	_step("land shapes", 0.05)
	_land_shapes()
	_place_spawn()
	_step("coastlines", 0.15)
	_coast_distance()
	_ramp_uplift()
	_step("river network", 0.2)
	_graph = RiverGraph.new(self)
	_graph.grow()
	_graph.elevate()
	_graph.make_streams()
	_step("land from rivers", 0.4)
	_graph.build_land()
	_craters()
	_step("seafloor", 0.55)
	_seafloor()
	_drainage()
	_step("lakes", 0.6)
	_lakes()
	_step("climate", 0.7)
	_climate()
	_step("water today", 0.8)
	_water_today()
	_step("rivers", 0.85)
	_rivers()
	_materials()
	_shift_to_spawn()
	_step("done", 1.0)
	return m


var debug_timing := false
var _t0 := 0


func _step(name: String, at: float) -> void:
	if debug_timing:
		print("  %s took %d ms" % [stage, Time.get_ticks_msec() - _t0])
		_t0 = Time.get_ticks_msec()
	stage = name
	progress = at


func _cx(i: int) -> float:
	return (i % n + 0.5) * cell - size * 0.5


func _cz(i: int) -> float:
	return (i / n + 0.5) * cell - size * 0.5


func _border(i: int) -> bool:
	var x := i % n
	var y := i / n
	return x == 0 or y == 0 or x == n - 1 or y == n - 1


# --- 1. land shapes and uplift -----------------------------------------------------

func _land_shapes() -> void:
	var count := n * n
	_shape.resize(count)
	_shape.fill(-1.0)
	_uplift.resize(count)
	_uplift.fill(0.0)
	var coast := FastNoiseLite.new()
	coast.seed = config.seed_for("coast")
	coast.frequency = 1.0 / 2600.0
	coast.fractal_octaves = 6
	var warp := FastNoiseLite.new()
	warp.seed = config.seed_for("coast-warp")
	warp.frequency = 1.0 / 7000.0
	warp.fractal_octaves = 3
	var hills := FastNoiseLite.new()
	hills.seed = config.seed_for("uplift")
	hills.frequency = 1.0 / 4000.0
	hills.fractal_octaves = 4
	for lm in landmasses:
		var reach := lm.radius * 1.5
		var x0 := clampi(int((lm.center.x - reach + size * 0.5) / cell), 1, n - 2)
		var x1 := clampi(int((lm.center.x + reach + size * 0.5) / cell), 1, n - 2)
		var y0 := clampi(int((lm.center.y - reach + size * 0.5) / cell), 1, n - 2)
		var y1 := clampi(int((lm.center.y + reach + size * 0.5) / cell), 1, n - 2)
		# continents are stretched along a random axis
		var rng := RandomNumberGenerator.new()
		rng.seed = lm.seed
		var axis := rng.randf() * TAU
		var stretch := rng.randf_range(1.0, 1.25)
		var ca := cos(axis)
		var sa := sin(axis)
		# islands keep their own shapes: warp them far less than a continent
		var wamp := lm.radius * 0.3 if lm.kind == Landmass.Kind.CONTINENT \
				else (300.0 if lm.kind == Landmass.Kind.VOLCANIC_CHAIN else 750.0)
		var is_cont := lm.kind == Landmass.Kind.CONTINENT
		# islands in 1 km buckets, so each cell only looks at the ones near it
		var near_isl := {}
		for q in lm.islands.size():
			var isl: Vector4 = lm.islands[q]
			var r := isl.z * 1.6 + wamp
			for by in range(floori((isl.y - r) / 1000.0), floori((isl.y + r) / 1000.0) + 1):
				for bx in range(floori((isl.x - r) / 1000.0), floori((isl.x + r) / 1000.0) + 1):
					var key := Vector2i(bx, by)
					if not near_isl.has(key):
						near_isl[key] = PackedInt32Array()
					near_isl[key].append(q)
		# the noise (and a continent's uplift) on a lattice every other cell,
		# interpolated in between: a quarter of the work, the same shapes
		var lw := (x1 - x0) / 2 + 2
		var lh := (y1 - y0) / 2 + 2
		var lat_wx := PackedFloat32Array()
		var lat_wz := PackedFloat32Array()
		var lat_cn := PackedFloat32Array()
		var lat_u := PackedFloat32Array()
		for ly in lh:
			for lx in lw:
				var px := (x0 + lx * 2 + 0.5) * cell - size * 0.5
				var pz := (y0 + ly * 2 + 0.5) * cell - size * 0.5
				lat_wx.append(warp.get_noise_2d(px, pz) * wamp)
				lat_wz.append(warp.get_noise_2d(pz + 9000.0, px - 4000.0) * wamp)
				lat_cn.append(coast.get_noise_2d(px, pz))
				var uc := 0.0
				if is_cont:
					uc = 0.18 + 0.12 * hills.get_noise_2d(px, pz)
					for belt in lm.belts:
						var bd := _polyline_distance(belt, Vector2(px, pz))
						uc += exp(-pow(bd / lm.belt_width, 2.0)) * (0.85 + 0.3 * hills.get_noise_2d(pz, px))
				lat_u.append(uc)
		for y in range(y0, y1 + 1):
			var fy := (y - y0) * 0.5
			var ly := int(fy)
			var ty := fy - ly
			for x in range(x0, x1 + 1):
				var i := y * n + x
				var px := (x + 0.5) * cell - size * 0.5
				var pz := (y + 0.5) * cell - size * 0.5
				var fx := (x - x0) * 0.5
				var lx := int(fx)
				var tx := fx - lx
				var l00 := ly * lw + lx
				var wx := px + lerpf(lerpf(lat_wx[l00], lat_wx[l00 + 1], tx), lerpf(lat_wx[l00 + lw], lat_wx[l00 + lw + 1], tx), ty)
				var wz := pz + lerpf(lerpf(lat_wz[l00], lat_wz[l00 + 1], tx), lerpf(lat_wz[l00 + lw], lat_wz[l00 + lw + 1], tx), ty)
				var cn := lerpf(lerpf(lat_cn[l00], lat_cn[l00 + 1], tx), lerpf(lat_cn[l00 + lw], lat_cn[l00 + lw + 1], tx), ty)
				var s := -1.0
				var u := 0.0
				match lm.kind:
					Landmass.Kind.CONTINENT:
						var dx := wx - lm.center.x
						var dz := wz - lm.center.y
						var a := (dx * ca + dz * sa) / stretch
						var b := (-dx * sa + dz * ca) * stretch
						s = 1.0 - sqrt(a * a + b * b) / lm.radius + cn * 0.35 * lm.coast_roughness
						u = lerpf(lerpf(lat_u[l00], lat_u[l00 + 1], tx), lerpf(lat_u[l00 + lw], lat_u[l00 + lw + 1], tx), ty)
					_:
						var volcanic := lm.kind == Landmass.Kind.VOLCANIC_CHAIN
						var bucket: PackedInt32Array = near_isl.get(Vector2i(floori(wx / 1000.0), floori(wz / 1000.0)), PackedInt32Array())
						for q in bucket:
							var isl: Vector4 = lm.islands[q]
							var d := Vector2(wx - isl.x, wz - isl.y).length() / isl.z
							if d > 1.6:
								continue
							var si := 1.0 - d * (1.3 if volcanic else 1.0) + cn * (0.3 if volcanic else 0.5) * lm.coast_roughness
							var ui := isl.w * (pow(maxf(0.0, 1.0 - d), 0.7) + 0.05) if volcanic \
									else isl.w * (0.3 + 0.7 * maxf(0.0, 1.0 - d))
							if si > s:
								s = si
							u = maxf(u, ui)
				# keep land off the world's edge
				var edge := size * 0.5 - maxf(absf(px), absf(pz))
				s = minf(s, (edge - 1200.0) / 2500.0)
				if s > _shape[i]:
					_shape[i] = s
					_uplift[i] = maxf(u, 0.02)
					m.owner[i] = lm.id + 1 if s > 0.0 else 0
	for i in count:
		if _shape[i] <= 0.0 or _border(i):
			_shape[i] = minf(_shape[i], -0.001)
			m.owner[i] = 0
		m.water_kind[i] = WorldMaps.WaterKind.LAND if _shape[i] > 0.0 else WorldMaps.WaterKind.OCEAN
	_is_land.resize(count)
	_arid.resize(count)
	for i in count:
		_is_land[i] = 1 if _shape[i] > 0.0 else 0
		_arid[i] = landmasses[m.owner[i] - 1].aridity if m.owner[i] > 0 else 0.0


static func _polyline_distance(line: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	for k in line.size() - 1:
		var a := line[k]
		var ab := line[k + 1] - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


func _land(i: int) -> bool:
	return _is_land[i] == 1


var spawn := Vector2.ZERO   ## Where the player starts, in layout coordinates.


# Offshore of the continent, away from the islands: march out from the
# continent's middle until well past its coast, and keep open water around it.
func _place_spawn() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed_for("spawn")
	var avoid: Array[float] = []
	for lm in landmasses:
		if lm.kind != Landmass.Kind.CONTINENT:
			avoid.append(lm.center.angle())
	var best_dir := 0.0
	var best_gap := -1.0
	for _try in 24:
		var a := rng.randf() * TAU
		var gap := PI
		for b in avoid:
			gap = minf(gap, absf(angle_difference(a, b)))
		if gap > best_gap:
			best_gap = gap
			best_dir = a
	var dir := Vector2.from_angle(best_dir)
	var coast_r := 0.0
	var r := 0.0
	while r < size * 0.45:
		var g := (dir * r + Vector2.ONE * size * 0.5) / cell
		var i := clampi(int(g.y), 0, n - 1) * n + clampi(int(g.x), 0, n - 1)
		if _shape[i] > 0.0:
			coast_r = r
		r += cell
	spawn = dir * (coast_r + 2500.0)
	var clear := 1500.0
	var g0 := m.to_grid(spawn.x - clear - 2000.0, spawn.y - clear - 2000.0)
	var g1 := m.to_grid(spawn.x + clear + 2000.0, spawn.y + clear + 2000.0)
	for y in range(clampi(floori(g0.y), 0, n - 1), clampi(ceili(g1.y), 0, n - 1) + 1):
		for x in range(clampi(floori(g0.x), 0, n - 1), clampi(ceili(g1.x), 0, n - 1) + 1):
			var i := y * n + x
			var d := Vector2(_cx(i), _cz(i)).distance_to(spawn)
			if d < clear + 2000.0:
				_shape[i] = minf(_shape[i], (d - clear) / 2000.0)
				if _shape[i] <= 0.0:
					_is_land[i] = 0
					m.owner[i] = 0
					m.water_kind[i] = WorldMaps.WaterKind.OCEAN


# Move everything so the spawn point is the world origin.
func _shift_to_spawn() -> void:
	m.center = -spawn
	for lm in landmasses:
		m.landmasses.append({"kind": lm.kind, "center": lm.center - spawn, "radius": lm.radius})
	for lake in m.lakes:
		lake.center -= spawn
		var r: Rect2 = lake.rect
		r.position -= spawn
		lake.rect = r
	var shift := Vector3(spawn.x, 0.0, spawn.y)
	for river in m.rivers:
		var pts: PackedVector3Array = river.points
		for k in pts.size():
			pts[k] -= shift
		river.points = pts


# Chamfer distance: land cells to the nearest sea cell, sea cells to the nearest land.
func _coast_distance() -> void:
	var count := n * n
	_dist.resize(count)
	var big := 1e9
	for i in count:
		_dist[i] = big
	# seed: cells next to the other kind
	var isl := _is_land
	var dist := _dist
	var nb := _nb
	for i in range(n + 1, count - n - 1):
		var land := isl[i]
		for k in 8:
			if isl[i + nb[k]] != land:
				dist[i] = cell * 0.5
				break
	var d1 := cell
	var d2 := cell * sqrt(2.0)
	for y in range(1, n - 1):
		var i := y * n
		for x in range(1, n - 1):
			i += 1
			var land := isl[i]
			var v := dist[i]
			var j := i - n - 1
			if isl[j] == land: v = minf(v, dist[j] + d2)
			j += 1
			if isl[j] == land: v = minf(v, dist[j] + d1)
			j += 1
			if isl[j] == land: v = minf(v, dist[j] + d2)
			j = i - 1
			if isl[j] == land: v = minf(v, dist[j] + d1)
			dist[i] = v
	for y in range(n - 2, 0, -1):
		var i := y * n + n - 1
		for x in range(n - 2, 0, -1):
			i -= 1
			var land := isl[i]
			var v := dist[i]
			var j := i + n + 1
			if isl[j] == land: v = minf(v, dist[j] + d2)
			j -= 1
			if isl[j] == land: v = minf(v, dist[j] + d1)
			j -= 1
			if isl[j] == land: v = minf(v, dist[j] + d2)
			j = i + 1
			if isl[j] == land: v = minf(v, dist[j] + d1)
			dist[i] = v


# Uplift fades toward the coast: gentle coastal plains on continents and
# archipelagos, steeper shores on the volcanoes.
func _ramp_uplift() -> void:
	var ramps := {Landmass.Kind.CONTINENT: 3000.0, Landmass.Kind.VOLCANIC_CHAIN: 450.0, Landmass.Kind.ARCHIPELAGO: 400.0}
	var by_owner := PackedFloat32Array([1.0])
	for lm in landmasses:
		by_owner.append(ramps[lm.kind])
	var owner := m.owner
	var up := _uplift
	var dist := _dist
	for i in n * n:
		if owner[i] == 0:
			up[i] = 0.0
		else:
			up[i] *= 0.1 + 0.9 * smoothstep(0.0, by_owner[owner[i]], dist[i])


# --- 2. mountains and valleys ----------------------------------------------------------

# Where water on the grid goes: a priority flood up from the coast (Barnes et
# al. 2014), lowest first; each cell drains into the cell that reached it, and
# little hollows are filled just enough (a centimetre a cell) to drain. On
# land made from the river network the water finds the network's valleys.
func _drainage() -> void:
	var count := n * n
	_recv.resize(count)
	_recv.fill(-1)
	_area.resize(count)
	var h := m.height
	var isl := _is_land
	var nb := _nb
	var seen := PackedByteArray()
	seen.resize(count)
	var heap := RiverGraph.Heap.new()
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			if isl[i] == 0:
				continue
			for k in 8:
				var j := i + nb[k]
				if isl[j] == 0:
					_recv[i] = j
					seen[i] = 1
					heap.push(h[i], i)
					break
	var order := PackedInt32Array()
	while not heap.empty():
		var i := heap.pop()
		order.append(i)
		var gx := i % n
		var gy := i / n
		if gx < 1 or gy < 1 or gx > n - 2 or gy > n - 2:
			continue
		for k in 8:
			var j := i + nb[k]
			if isl[j] == 0 or seen[j] == 1:
				continue
			seen[j] = 1
			h[j] = maxf(h[j], h[i] + 0.01)
			_recv[j] = i
			heap.push(h[j], j)
	_order = order
	_accumulate_area()


func _accumulate_area() -> void:
	var area := _area
	var recv := _recv
	var isl := _is_land
	var order := _order
	area.fill(cell * cell)
	for k in range(order.size() - 1, -1, -1):
		var i := order[k]
		var j := recv[i]
		if isl[j] == 1:
			area[j] += area[i]


# Young volcanoes get a summit crater.
func _craters() -> void:
	var h := m.height
	for lm in landmasses:
		if lm.kind != Landmass.Kind.VOLCANIC_CHAIN:
			continue
		for isl in lm.islands:
			if isl.w < 0.75:
				continue
			var cx := clampi(int((isl.x + size * 0.5) / cell), 2, n - 3)
			var cy := clampi(int((isl.y + size * 0.5) / cell), 2, n - 3)
			var rc := isl.z * 0.13
			var top := 0.0
			var reach := ceili(rc * 1.6 / cell)
			for y in range(maxi(cy - reach, 1), mini(cy + reach, n - 2) + 1):
				for x in range(maxi(cx - reach, 1), mini(cx + reach, n - 2) + 1):
					top = maxf(top, h[y * n + x])
			var depth := minf(top * 0.12, 160.0)
			for y in range(maxi(cy - reach, 1), mini(cy + reach, n - 2) + 1):
				for x in range(maxi(cx - reach, 1), mini(cx + reach, n - 2) + 1):
					var i := y * n + x
					var d := Vector2(_cx(i) - isl.x, _cz(i) - isl.y).length() / rc
					if d < 1.0 and _land(i):
						# bowl inside the rim
						h[i] = minf(h[i], top - depth * (1.0 - d * d))
					elif d < 1.6 and _land(i):
						# raise the rim a little
						h[i] = maxf(h[i], lerpf(top, h[i], (d - 1.0) / 0.6))


# --- 3. seafloor ---------------------------------------------------------------------------

func _seafloor() -> void:
	var h := m.height
	var bumps := FastNoiseLite.new()
	bumps.seed = config.seed_for("seafloor")
	bumps.fractal_octaves = 4
	# the whole grid at once (natively, 8 bits is plenty for bumps)
	bumps.frequency = cell / 1800.0
	bumps.offset = Vector3(-size * 0.5 / cell + 0.5, -size * 0.5 / cell + 0.5, 0.0)
	var bump := bumps.get_image(n, n, false, false, false).get_data()
	for i in n * n:
		if _land(i):
			continue
		var d := _dist[i]
		# shelf, slope, deep sea
		var depth := 1.0 + 45.0 * (1.0 - exp(-d / 1400.0)) + 2600.0 * smoothstep(3000.0, 16000.0, d)
		depth *= 1.0 + 0.25 * (bump[i] / 127.5 - 1.0)
		h[i] = -maxf(depth, 0.5)


# --- 4. lakes ----------------------------------------------------------------------------------

func _lakes() -> void:
	var count := n * n
	_lake_id.resize(count)
	_lake_id.fill(0)
	_mark.resize(count)
	_mark.fill(0)
	var h := m.height
	var donors := _donor_lists()
	var dn: PackedInt32Array = donors[0]
	var dl: PackedInt32Array = donors[1]
	var placed: Array[Vector2] = []
	for lm in landmasses:
		if lm.lake_count == 0:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = lm.seed + 77
		var min_area := 8e6 if lm.kind == Landmass.Kind.CONTINENT else 1.5e6
		var cands := PackedInt32Array()
		for i in _order:
			if m.owner[i] != lm.id + 1 or _area[i] < min_area or _dist[i] < 900.0 or h[i] < 6.0:
				continue
			var j := _recv[i]
			if not _land(j) or (h[i] - h[j]) / cell > 0.04:
				continue
			cands.append(i)
		# shuffle deterministically
		for k in range(cands.size() - 1, 0, -1):
			var r := rng.randi_range(0, k)
			var t := cands[k]
			cands[k] = cands[r]
			cands[r] = t
		var made := 0
		for node in cands:
			if made >= lm.lake_count:
				break
			var p := Vector2(_cx(node), _cz(node))
			var near := false
			for q in placed:
				if p.distance_to(q) < 3000.0:
					near = true
					break
			if near or _lake_id[node] != 0:
				continue
			# the outlet's drainage basin near it
			var basin := _upstream(node, p, 4500.0, dn, dl)
			for i in basin:
				_mark[i] = 1
			# scoop a basin around the outlet, then flood it to the level
			var radius := rng.randf_range(450.0, 1200.0) if lm.kind == Landmass.Kind.CONTINENT else rng.randf_range(200.0, 500.0)
			var rise := rng.randf_range(12.0, 35.0)
			var level := h[node] + rise
			for i in basin:
				var d := Vector2(_cx(i), _cz(i)).distance_to(p) / radius
				if d < 1.0:
					h[i] = minf(h[i], h[node] + rise * (0.2 + 1.1 * d * d))
			# the sill: the outlet and its neighbours outside the basin dam the lake
			var dam := PackedInt32Array([node])
			for k in 8:
				var j := node + _nb[k]
				if _mark[j] == 0 and _land(j) and _lake_id[j] == 0:
					dam.append(j)
			var region := PackedInt32Array()
			for _try in 6:
				region = _flood(node, level)
				var spill := level
				for i in region:
					for k in 8:
						var j := i + _nb[k]
						if _mark[j] == 0 and not dam.has(j) and h[j] < spill:
							spill = h[j]
				if spill >= level:
					break
				level = spill - 0.3
			for i in basin:
				_mark[i] = 0
			if region.size() < 8 or level - h[node] < 2.5:
				continue
			var dry_climate := lm.aridity * rng.randf()
			var endorheic := dry_climate > 0.45
			var id := m.lakes.size() + 1
			var rect := Rect2(p, Vector2.ZERO)
			for i in region:
				_lake_id[i] = id
				rect = rect.expand(Vector2(_cx(i), _cz(i)))
			_deepen(region, level)
			# the sill holds the lake; a terminal lake's rim stands above it
			for i in dam:
				h[i] = maxf(h[i], level + (3.0 if endorheic else 0.0))
			var inflows := 0
			for i in region:
				for k in range(dn[i], dn[i + 1]):
					if _lake_id[dl[k]] == 0 and _area[dl[k]] > 1e6:
						inflows += 1
			_regions.append(region)
			m.lakes.append({"center": p, "level": level, "full_level": level, "endorheic": endorheic,
					"dry": false, "area": region.size() * cell * cell, "rect": rect.grow(cell),
					"node": node, "inflows": inflows})
			placed.append(p)
			made += 1


func _donor_lists() -> Array:
	var count := n * n
	var dn := PackedInt32Array()
	dn.resize(count + 1)
	for i in _order:
		dn[_recv[i] + 1] += 1
	for i in count:
		dn[i + 1] += dn[i]
	var fill := dn.duplicate()
	var dl := PackedInt32Array()
	dl.resize(dn[count])
	for i in _order:
		var j := _recv[i]
		dl[fill[j]] = i
		fill[j] += 1
	return [dn, dl]


# The outlet's drainage basin (everything upstream of it), within reach of p.
func _upstream(node: int, p: Vector2, reach: float, dn: PackedInt32Array, dl: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var queue := PackedInt32Array([node])
	var head := 0
	var r2 := reach * reach
	while head < queue.size():
		var i := queue[head]
		head += 1
		for k in range(dn[i], dn[i + 1]):
			var j := dl[k]
			if _lake_id[j] == 0 and Vector2(_cx(j), _cz(j)).distance_squared_to(p) < r2:
				out.append(j)
				queue.append(j)
	return out


# Basin cells (marked) below the level, connected to the outlet.
func _flood(node: int, level: float) -> PackedInt32Array:
	var h := m.height
	var out := PackedInt32Array()
	var seen := {}
	var queue := PackedInt32Array([node])
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		for k in 8:
			var j := i + _nb[k]
			if _mark[j] == 1 and h[j] < level and not seen.has(j):
				seen[j] = true
				out.append(j)
				queue.append(j)
	return out


# A bowl: deeper toward the middle of the lake.
func _deepen(region: PackedInt32Array, level: float) -> void:
	var h := m.height
	var inside := {}
	for i in region:
		inside[i] = true
	var dist := {}
	var queue := PackedInt32Array()
	for i in region:
		for k in 8:
			if not inside.has(i + _nb[k]):
				dist[i] = 1
				queue.append(i)
				break
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		for k in 8:
			var j := i + _nb[k]
			if inside.has(j) and not dist.has(j):
				dist[j] = dist[i] + 1
				queue.append(j)
	for i in region:
		var d: int = dist.get(i, 1)
		h[i] = minf(h[i], level - 1.0) - minf(d * cell * 0.025, 35.0)


# --- 5. climate -----------------------------------------------------------------------------------

func _climate() -> void:
	var count := n * n
	var h := m.height
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed_for("climate")
	var wind_a := rng.randf() * TAU
	var wind := Vector2(cos(wind_a), sin(wind_a))
	var wetness := rng.randf_range(0.7, 1.3)
	var t0 := 27.0 - 0.38 * absf(config.latitude)
	for i in count:
		m.temperature[i] = t0 - 0.0065 * maxf(h[i], 0.0)
	# sweep downwind: every cell takes its moisture from the cells upwind of it
	var keys := PackedInt64Array()
	keys.resize(count)
	for i in count:
		var along := (i % n) * wind.x + (i / n) * wind.y
		keys[i] = (int((along + 2.0 * n) * 64.0) << 22) | i
	keys.sort()
	var moist := PackedFloat32Array()
	moist.resize(count)
	moist.fill(1.0)
	# the upwind neighbour and the two either side of it, on the ring of eight
	var ring := [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
			Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
	var k0 := posmod(roundi((wind_a + PI) / (PI / 4.0)), 8)
	var ofs := func(v: Vector2i) -> int: return v.y * n + v.x
	var up: int = ofs.call(ring[k0])
	var up_a: int = ofs.call(ring[(k0 + 1) % 8])
	var up_b: int = ofs.call(ring[(k0 + 7) % 8])
	for key in keys:
		var i := int(key & 0x3fffff)
		var gx := i % n
		var gy := i / n
		if gx < 1 or gy < 1 or gx > n - 2 or gy > n - 2:
			continue
		var m_up := (moist[i + up] * 2.0 + moist[i + up_a] + moist[i + up_b]) * 0.25
		if not _land(i):
			moist[i] = lerpf(m_up, 1.0, 0.03)
			continue
		var lift := maxf(0.0, h[i] - h[i + up]) / cell
		var p := m_up * (0.55 + 30.0 * lift) * wetness * (1.25 - 0.9 * _arid[i])
		m.rainfall[i] = p
		moist[i] = maxf(0.0, m_up - p * cell / 60000.0)


# --- 6. water today -----------------------------------------------------------------------------------

var _flow := PackedFloat32Array()   # m^3/s through each cell today


func _water_today() -> void:
	var count := n * n
	_flow.resize(count)
	_flow.fill(0.0)
	var ca := cell * cell
	var lake_inflow := {}
	for i in count:
		if _land(i):
			var et := (0.35 + 0.035 * maxf(m.temperature[i], 0.0)) * (0.7 + 0.6 * _arid[i])
			_flow[i] = maxf(0.0, m.rainfall[i] - et * 0.75) * ca / YEAR
	var lake_nodes := {}
	for li in m.lakes.size():
		lake_nodes[int(m.lakes[li].node)] = li
	for k in range(_order.size() - 1, -1, -1):
		var i := _order[k]
		var j := _recv[i]
		# losing streams: channels shed water into the ground and the air
		if _area[i] > 1e6:
			_flow[i] = maxf(0.0, _flow[i] - 0.0005 * _arid[i] * cell / 48.0)
		if lake_nodes.has(i):
			var li: int = lake_nodes[i]
			var lake: Dictionary = m.lakes[li]
			var q_in := _flow[i]
			var et := 0.4 + 0.04 * maxf(m.temperature[i], 0.0)
			var evap_full: float = et * float(lake.area) / YEAR
			if q_in >= evap_full and not lake.endorheic:
				_flow[i] = q_in - evap_full
			else:
				lake.level = _balance_level(li, q_in, et)
				lake.dry = lake.level <= WorldMaps.NO_WATER or q_in < evap_full * 0.03
				_flow[i] = 0.0
			lake_inflow[li] = q_in
		if _land(j):
			_flow[j] += _flow[i]
	# lake surfaces, spread a few cells past the shore so they interpolate cleanly
	for i in count:
		var li := _lake_id[i] - 1
		if li < 0:
			continue
		var lake: Dictionary = m.lakes[li]
		if lake.dry:
			m.water_kind[i] = WorldMaps.WaterKind.DRY_LAKE
		else:
			m.water_kind[i] = WorldMaps.WaterKind.LAKE
			m.water_level[i] = lake.level
	var wl := m.water_level
	for lake in m.lakes:
		var r: Rect2 = lake.rect
		var g0 := m.to_grid(r.position.x, r.position.y)
		var g1 := m.to_grid(r.end.x, r.end.y)
		var x0 := clampi(floori(g0.x) - 4, 1, n - 2)
		var x1 := clampi(ceili(g1.x) + 4, 1, n - 2)
		var y0 := clampi(floori(g0.y) - 4, 1, n - 2)
		var y1 := clampi(ceili(g1.y) + 4, 1, n - 2)
		for _pass in 3:
			var grow := {}
			for y in range(y0, y1 + 1):
				for x in range(x0, x1 + 1):
					var i := y * n + x
					if wl[i] > WorldMaps.NO_WATER:
						continue
					for k in 8:
						var v := wl[i + _nb[k]]
						# only up the shore: never across a dam into a lower valley
						if v > grow.get(i, WorldMaps.NO_WATER) and m.height[i] >= v - 1.0:
							grow[i] = v
			for i in grow:
				wl[i] = grow[i]


# Lake level where evaporation from its surface equals the inflow.
func _balance_level(li: int, q_in: float, et: float) -> float:
	var h := m.height
	var lake: Dictionary = m.lakes[li]
	var beds := PackedFloat32Array()
	for i in _regions[li]:
		beds.append(h[i])
	beds.sort()
	var per_cell := et * cell * cell / YEAR
	var cells := clampi(int(q_in / per_cell), 0, beds.size())
	if cells == 0:
		return WorldMaps.NO_WATER
	return minf(beds[cells - 1] + 0.5, lake.full_level)


# --- 7. rivers -------------------------------------------------------------------------------------------

enum { RIVER, OXBOW, SCAR }   ## River kinds: flowing (or dry) river, oxbow lake, meander scar.



const STEP_RIVER := 24.0   ## Spacing of river centreline points before meandering (m).


# The streams big enough to be rivers (draining more than ~0.3 km^2), as
# evenly spaced centrelines, split where they run through a lake; then the
# meanders, and the oxbows and scars they leave.
func _rivers() -> void:
	var mean_runoff := 0.0   # past climate: channels carry this much per m^2 when full
	for i in _order:
		mean_runoff += m.rainfall[i]
	mean_runoff = 0.5 * mean_runoff / maxf(_order.size(), 1) / YEAR
	var runs_of: Array[PackedInt32Array] = []   # each stream's rivers (split by lakes)
	runs_of.resize(_graph.streams.size())
	for si in _graph.streams.size():
		var st: Dictionary = _graph.streams[si]
		var sp: PackedVector2Array = st.points
		if sp.size() < 2:
			continue
		var gi := m.index_at(sp[0].x, sp[0].y)
		var lm := landmasses[maxi(m.owner[gi], 1) - 1]
		var threshold := 0.35e6 if lm.kind == Landmass.Kind.CONTINENT else 0.25e6
		var sa: PackedFloat32Array = st.area
		var k0 := -1
		for k in sa.size():
			if sa[k] >= threshold:
				k0 = k
				break
		if k0 < 0 or k0 > sp.size() - 2:
			continue
		var line := _resample_stream(st, k0)
		var pts: PackedVector2Array = line[0]
		var el: PackedFloat32Array = line[1]
		var ar: PackedFloat32Array = line[2]
		var fp: PackedFloat32Array = line[3]
		# runs outside lakes
		var start := 0
		for k in pts.size() + 1:
			var in_lake := false
			if k < pts.size():
				var li := _lake_id[m.index_at(pts[k].x, pts[k].y)] - 1
				in_lake = li >= 0 and not m.lakes[li].dry
			if k < pts.size() and not in_lake:
				continue
			# a run [start, k): into the lake it reaches (one point in it), if any
			var end := mini(k + 1, pts.size()) if k < pts.size() else k
			if end - start >= 3:
				var river := _make_river(pts, el, ar, fp, start, end, mean_runoff)
				river.joins = -1
				if k == pts.size() and st.joins >= 0:
					river.joins = _nearest_run(runs_of[st.joins], pts[pts.size() - 1])
				runs_of[si].append(m.rivers.size())
				m.rivers.append(river)
			start = k + 1
	# meanders on the floodplains
	var relics: Array[Dictionary] = []
	for k in m.rivers.size():
		var river: Dictionary = m.rivers[k]
		var rng := RandomNumberGenerator.new()
		rng.seed = config.seed_for("meander:%d" % k)
		var mid: Vector3 = river.points[river.points.size() / 2]
		relics.append_array(MeanderSim.run(river, rng, _arid[m.index_at(mid.x, mid.z)]))
	# tributaries end exactly on the (now meandering) river they join
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
	_confluence_widths()
	m.rivers.append_array(relics)
	for river in m.rivers:
		river.erase("fp")
		if river.kind == OXBOW:
			var f := PackedFloat32Array()
			f.resize(river.points.size())
			f.fill(1.0)
			river.fill = f
		else:
			_fill(river)


# Of a stream's rivers, the one passing nearest p (-1 if none).
func _nearest_run(runs: PackedInt32Array, p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for ri in runs:
		for q: Vector3 in m.rivers[ri].points:
			var d := Vector2(q.x - p.x, q.z - p.y).length_squared()
			if d < best_d:
				best_d = d
				best = ri
	return best if best_d < 200.0 * 200.0 else -1


# A stream from point k0 on, evenly spaced, plus a last point just offshore
# if it reaches the sea: positions, elevations, drained areas, floodplains.
func _resample_stream(st: Dictionary, k0: int) -> Array:
	var sp: PackedVector2Array = st.points
	var se: PackedFloat32Array = st.elev
	var sa: PackedFloat32Array = st.area
	var sf: PackedFloat32Array = st.fp
	var src := sp.slice(k0)
	var e := se.slice(k0)
	var a := sa.slice(k0)
	var f := sf.slice(k0)
	if st.mouth != Vector2.INF:
		src.append(st.mouth)
		e.append(0.0)
		a.append(a[a.size() - 1])
		f.append(f[f.size() - 1])
	var arc := PackedFloat32Array([0.0])
	for k in range(1, src.size()):
		arc.append(arc[k - 1] + src[k].distance_to(src[k - 1]))
	var total := arc[arc.size() - 1]
	var count := maxi(int(total / STEP_RIVER), 1) + 1
	var pts := PackedVector2Array()
	var el := PackedFloat32Array()
	var ar := PackedFloat32Array()
	var fp := PackedFloat32Array()
	var j := 0
	for k in count:
		var s := total * k / (count - 1)
		while j < arc.size() - 2 and arc[j + 1] < s:
			j += 1
		var t := clampf((s - arc[j]) / maxf(arc[j + 1] - arc[j], 0.001), 0.0, 1.0)
		pts.append(src[j].lerp(src[j + 1], t))
		el.append(lerpf(e[j], e[j + 1], t))
		ar.append(lerpf(a[j], a[j + 1], t))
		fp.append(lerpf(f[j], f[j + 1], t))
	return [pts, el, ar, fp]


# One river from points [a, b): the water surface is the stream's elevation
# (never above the ground, always falling), sized from today's flow (the
# past's for dry beds).
func _make_river(pts: PackedVector2Array, el: PackedFloat32Array, ar: PackedFloat32Array,
		fp: PackedFloat32Array, a: int, b: int, past_runoff: float) -> Dictionary:
	var count := b - a
	var p3 := PackedVector3Array()
	var hw := PackedFloat32Array()
	var depth := PackedFloat32Array()
	var wet := PackedByteArray()
	var speed := PackedFloat32Array()
	var flow := PackedFloat32Array()
	var ffp := PackedFloat32Array()
	for k in range(a, b):
		var s := minf(el[k], m.height_at(pts[k].x, pts[k].y))
		if k > a:
			s = minf(s, p3[k - a - 1].y)
		p3.append(Vector3(pts[k].x, s, pts[k].y))
		ffp.append(fp[k])
		# today's flow: from the grid cell beside the channel whose drained
		# area best matches this river's (not a bigger river's next to it)
		var g := m.to_grid(pts[k].x, pts[k].y)
		var q := 0.0
		var best := INF
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var i := clampi(roundi(g.y) + dy, 0, n - 1) * n + clampi(roundi(g.x) + dx, 0, n - 1)
				var miss := absf(log(maxf(_area[i], 1.0) / maxf(ar[k], 1.0)))
				if miss < best:
					best = miss
					q = _flow[i]
		# (offshore, at the mouth, the grid has no river: keep the last flow)
		if not _land(m.index_at(pts[k].x, pts[k].y)) and flow.size() > 0:
			q = flow[flow.size() - 1]
		flow.append(q)
	for k in count:
		var q_past := ar[a + k] * past_runoff
		var q := flow[k]
		var is_wet := q >= 0.04
		var qw := maxf(q if is_wet else q_past, q_past * 0.6)
		hw.append(clampf(9.0 * sqrt(qw) + 6.0, 6.0, 160.0))
		depth.append(clampf(0.8 * pow(maxf(qw, 0.05), 0.35) + 0.8, 0.8, 8.0))
		wet.append(1 if is_wet else 0)
		# big rivers run at a metre or two a second even on a gentle plain,
		# and anything runs faster down a steep surface
		var lo := maxi(k - 3, 0)
		var hi := mini(k + 3, count - 1)
		var drop := p3[lo].y - p3[hi].y
		var run := maxf(STEP_RIVER * (hi - lo), 1.0)
		speed.append(clampf(0.8 + 0.08 * sqrt(q) + 8.0 * sqrt(maxf(drop, 0.0) / run), 0.8, 4.5))
	return {"points": p3, "half_width": hw, "depth": depth, "flow": flow, "wet": wet,
			"speed": speed, "fp": ffp, "kind": RIVER, "joins": -1}


# Downstream of a confluence a river is wider (and deeper) than either
# stream above it: widths add as the square root of the summed flows, and a
# river never narrows downstream. A tributary's last point (on the main
# river) keeps the tributary's own size.
func _confluence_widths() -> void:
	for river in m.rivers:
		var hw: PackedFloat32Array = river.half_width
		var dep: PackedFloat32Array = river.depth
		var c := hw.size()
		if c >= 2:
			hw[c - 1] = hw[c - 2]
			dep[c - 1] = dep[c - 2]
		river.half_width = hw
		river.depth = dep
	for _pass in 2:
		for river in m.rivers:
			var j: int = river.joins
			if j < 0:
				continue
			var main: Dictionary = m.rivers[j]
			var mp: PackedVector3Array = main.points
			var end: Vector3 = river.points[river.points.size() - 1]
			var kj := 0
			var best := INF
			for k in mp.size():
				var d := Vector2(mp[k].x - end.x, mp[k].z - end.z).length_squared()
				if d < best:
					best = d
					kj = k
			var thw: PackedFloat32Array = river.half_width
			var tdep: PackedFloat32Array = river.depth
			var mhw: PackedFloat32Array = main.half_width
			var mdep: PackedFloat32Array = main.depth
			var t_hw := thw[thw.size() - 1]
			var t_d := tdep[tdep.size() - 1]
			var above_hw := mhw[maxi(kj - 1, 0)]
			var above_d := mdep[maxi(kj - 1, 0)]
			var w := sqrt(above_hw * above_hw + t_hw * t_hw)
			var dd := sqrt(above_d * above_d + t_d * t_d) * 0.85
			# eased in over ~170 m below the junction, so the channel flares
			# smoothly instead of stepping out into a wedge
			for k in range(kj, mhw.size()):
				var e := smoothstep(0.0, 1.0, float(k - kj + 1) / 14.0)
				mhw[k] = maxf(mhw[k], lerpf(above_hw, w, e))
				mdep[k] = maxf(mdep[k], lerpf(above_d, dd, e))
			main.half_width = mhw
			main.depth = mdep
	for river in m.rivers:
		var hw: PackedFloat32Array = river.half_width
		for k in range(1, hw.size()):
			hw[k] = maxf(hw[k], hw[k - 1])
		river.half_width = hw


# Water thins in where a river starts to flow (a spring, or a dry bed coming
# alive) and out where it dries up, instead of appearing at full width; and
# every channel narrows toward its head.
func _fill(river: Dictionary) -> void:
	var pts: PackedVector3Array = river.points
	var wet: PackedByteArray = river.wet
	var hw: PackedFloat32Array = river.half_width
	var count := pts.size()
	var arc := PackedFloat32Array([0.0])
	for k in range(1, count):
		arc.append(arc[k - 1] + Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length())
	var fill := PackedFloat32Array()
	fill.resize(count)
	var since_on := INF
	for k in count:
		if wet[k] == 0:
			since_on = INF
			fill[k] = 0.0
			continue
		if since_on == INF:
			since_on = arc[k]
		fill[k] = smoothstep(0.0, 350.0, arc[k] - since_on) if k > 0 or river.kind == RIVER else 1.0
	# and fade out before drying up
	var until_off := INF
	for k in range(count - 1, -1, -1):
		if wet[k] == 0:
			until_off = arc[k]
			continue
		if until_off < INF:
			fill[k] = minf(fill[k], smoothstep(0.0, 200.0, until_off - arc[k]))
	if river.kind == RIVER:
		for k in count:
			hw[k] *= lerpf(0.4, 1.0, smoothstep(0.0, 300.0, arc[k]))
	river.fill = fill
	river.half_width = hw


# --- ground ------------------------------------------------------------------------------------------------

func _materials() -> void:
	for i in n * n:
		if not _land(i):
			m.material[i] = WorldMaps.Ground.SAND
			continue
		if m.water_kind[i] == WorldMaps.WaterKind.DRY_LAKE or m.water_kind[i] == WorldMaps.WaterKind.LAKE:
			m.material[i] = WorldMaps.Ground.LAKEBED
			continue
		var lm := landmasses[m.owner[i] - 1]
		var mat := WorldMaps.Ground.DIRT
		match lm.kind:
			Landmass.Kind.ARCHIPELAGO: mat = WorldMaps.Ground.SAND
			Landmass.Kind.VOLCANIC_CHAIN: mat = WorldMaps.Ground.ROCK
		if m.height[i] < 2.5 and _dist[i] < 150.0:
			mat = WorldMaps.Ground.SAND   # beaches
		m.material[i] = mat
