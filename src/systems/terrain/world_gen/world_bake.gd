class_name WorldBake
extends RefCounted
## Bakes a world from its seed, once, when the world is created. Pure CPU and
## deterministic: the same seed and VERSION give the same world on any machine.
##
## 1. Layout: WorldLayout places the landmasses; each gives a land shape and
##    an uplift rate (how fast the ground rises).
## 2. Mountains and valleys: the steady state of stream-power erosion. Where
##    uplift and river erosion balance, a channel's slope is U / (K sqrt(A))
##    (A = area draining through it), so heights follow from the drainage tree
##    in one upstream pass. A few rounds of re-routing water down the new
##    slopes and recomputing give dendritic valleys and sharp ridges, with no
##    time-stepped simulation (after Cordonnier et al. 2016; Schott et al. 2023).
## 3. Seafloor: sandy shelves falling to the deep sea.
## 4. Lakes: chosen on river valleys and dammed behind a rock sill, so every
##    lake is fed by a river (wet or dry). Some have no outlet (terminal lakes).
## 5. Climate: temperature from height; rain from moist sea wind rising over
##    the land, with rain shadows behind mountains.
## 6. Water today: runoff accumulated down the valleys. Channels were carved
##    by a wetter past, so where today's flow runs out the riverbed is dry.
##    Lakes fill to their sills or shrink until evaporation matches inflow.
## 7. Rivers become smooth centrelines and a nearest-river field for Terrain.

const VERSION := 7
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
var _jitter := PackedFloat32Array()
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
	_step("mountains and valleys", 0.2)
	_erode()
	_step("seafloor", 0.55)
	_seafloor()
	_step("lakes", 0.6)
	_lakes()
	_step("climate", 0.7)
	_climate()
	_step("rivers", 0.8)
	_water_today()
	_step("river field", 0.88)
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
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var i := y * n + x
				var px := (x + 0.5) * cell - size * 0.5
				var pz := (y + 0.5) * cell - size * 0.5
				# islands keep their own shapes: warp them far less than a continent
				var wamp := lm.radius * 0.3 if lm.kind == Landmass.Kind.CONTINENT \
						else (300.0 if lm.kind == Landmass.Kind.VOLCANIC_CHAIN else 750.0)
				var wx := px + warp.get_noise_2d(px, pz) * wamp
				var wz := pz + warp.get_noise_2d(pz + 9000.0, px - 4000.0) * wamp
				var cn := coast.get_noise_2d(px, pz)
				var s := -1.0
				var u := 0.0
				match lm.kind:
					Landmass.Kind.CONTINENT:
						var dx := wx - lm.center.x
						var dz := wz - lm.center.y
						var a := (dx * ca + dz * sa) / stretch
						var b := (-dx * sa + dz * ca) * stretch
						s = 1.0 - sqrt(a * a + b * b) / lm.radius + cn * 0.35 * lm.coast_roughness
						u = 0.18 + 0.12 * hills.get_noise_2d(px, pz)
						for belt in lm.belts:
							var bd := _polyline_distance(belt, Vector2(px, pz))
							u += exp(-pow(bd / lm.belt_width, 2.0)) * (0.85 + 0.3 * hills.get_noise_2d(pz, px))
					_:
						var volcanic := lm.kind == Landmass.Kind.VOLCANIC_CHAIN
						for isl in lm.islands:
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

func _erode() -> void:
	var count := n * n
	_recv.resize(count)
	_area.resize(count)
	var h := m.height
	var jit := FastNoiseLite.new()
	jit.seed = config.seed_for("drainage")
	jit.frequency = 1.0 / 900.0
	jit.fractal_octaves = 3
	_jitter.resize(count)
	for i in count:
		_jitter[i] = 1.0 + 0.35 * jit.get_noise_2d(_cx(i), _cz(i))
		h[i] = 0.0
	var rounds := 6
	for r in rounds:
		_route(h, r == 0)
		_accumulate_area()
		# steady state: slope = U / sqrt(A), summed upstream from the coast
		var recv := _recv
		var isl := _is_land
		var up := _uplift
		var area := _area
		var diag := sqrt(2.0)
		for i in _order:
			var j := recv[i]
			var dj := absi(j - i)
			var dd := cell if dj == 1 or dj == n else cell * diag
			h[i] = (h[j] if isl[j] == 1 else 0.0) + dd * up[i] * 40.0 / sqrt(area[i])
		progress = 0.2 + 0.3 * (r + 1) / rounds
	# scale each landmass to its target peak, then cap slopes at a talus angle
	var peaks := PackedFloat32Array()
	peaks.resize(landmasses.size())
	for i in _order:
		var o := m.owner[i] - 1
		peaks[o] = maxf(peaks[o], h[i])
	for i in _order:
		var o := m.owner[i] - 1
		h[i] *= landmasses[o].peak / maxf(peaks[o], 1.0)
	var talus := tan(deg_to_rad(30.0))
	for i in _order:
		var j := _recv[i]
		var dd := cell * (1.0 if absi(j - i) == 1 or absi(j - i) == n else sqrt(2.0))
		h[i] = minf(h[i], (h[j] if _land(j) else 0.0) + dd * talus)
		h[i] = maxf(h[i], 0.3)
	_craters()
	m.height = h


# Downhill receivers and an upstream order. The first round routes toward the
# coast (the chamfer distance always falls toward it); later rounds take the
# steepest way down, with a little spatial jitter for meanders.
func _route(h: PackedFloat32Array, first: bool) -> void:
	var count := n * n
	var recv := _recv
	var isl := _is_land
	var dist := _dist
	var jit := _jitter
	var nb := _nb
	var nd := _nd
	recv.fill(-1)
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			if isl[i] == 0:
				continue
			var best := -1
			var best_v := -INF
			if first:
				var di := dist[i]
				for k in 8:
					var j := i + nb[k]
					if isl[j] == 0:
						best = j
						break
					if dist[j] < di:
						var v := -dist[j] * jit[j]
						if v > best_v:
							best_v = v
							best = j
			else:
				var hi := h[i]
				for k in 8:
					var j := i + nb[k]
					var hj := h[j] if isl[j] == 1 else -1.0
					if hj < hi:
						var v := (hi - hj) / nd[k] * jit[j]
						if v > best_v:
							best_v = v
							best = j
			recv[i] = best
	_build_order()


# Receivers before donors (breadth-first up from the coast).
func _build_order() -> void:
	var count := n * n
	var recv := _recv
	var isl := _is_land
	var donors_n := PackedInt32Array()
	donors_n.resize(count + 1)
	var queue := PackedInt32Array()
	for i in count:
		var j := recv[i]
		if j >= 0:
			if isl[j] == 1:
				donors_n[j + 1] += 1
			else:
				queue.append(i)
	for i in count:
		donors_n[i + 1] += donors_n[i]
	var fill := donors_n.duplicate()
	var donors := PackedInt32Array()
	donors.resize(donors_n[count])
	for i in count:
		var j := recv[i]
		if j >= 0 and isl[j] == 1:
			donors[fill[j]] = i
			fill[j] += 1
	var total := queue.size()
	for i in count:
		if recv[i] >= 0 and isl[recv[i]] == 1:
			total += 1
	var head := 0
	var tail := queue.size()
	queue.resize(total)
	while head < tail:
		var i := queue[head]
		head += 1
		for k in range(donors_n[i], donors_n[i + 1]):
			queue[tail] = donors[k]
			tail += 1
	queue.resize(tail)
	_order = queue


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
	bumps.frequency = 1.0 / 1800.0
	bumps.fractal_octaves = 4
	for i in n * n:
		if _land(i):
			continue
		var d := _dist[i]
		# shelf, slope, deep sea
		var depth := 1.0 + 45.0 * (1.0 - exp(-d / 1400.0)) + 2600.0 * smoothstep(3000.0, 16000.0, d)
		depth *= 1.0 + 0.25 * bumps.get_noise_2d(_cx(i), _cz(i))
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

func _channel(i: int) -> bool:
	var lm := landmasses[m.owner[i] - 1]
	var threshold := 0.35e6 if lm.kind == Landmass.Kind.CONTINENT else 0.25e6
	return _land(i) and _lake_id[i] == 0 and _area[i] >= threshold


func _rivers() -> void:
	var count := n * n
	var h := m.height
	var is_ch := PackedByteArray()
	is_ch.resize(count)
	var has_ch_donor := PackedByteArray()
	has_ch_donor.resize(count)
	for i in _order:
		if _channel(i):
			is_ch[i] = 1
			has_ch_donor[_recv[i]] = 1
	var visited := PackedByteArray()
	visited.resize(count)
	var river_of := PackedInt32Array()   # which river first ran through each cell
	river_of.resize(count)
	river_of.fill(-1)
	var mean_runoff := 0.0   # past climate: channels carry this much per m^2 when full
	for i in _order:
		mean_runoff += m.rainfall[i]
	mean_runoff = 0.5 * mean_runoff / maxf(_order.size(), 1) / YEAR
	for i in _order:
		if is_ch[i] == 0 or has_ch_donor[i] == 1:
			continue
		# a channel head: follow it down to the sea, a lake or a junction
		var pts := PackedVector3Array()
		var flows := PackedFloat32Array()
		var areas := PackedFloat32Array()
		var c := i
		var joins := -1
		while true:
			var land := _land(c)
			var in_lake := _lake_id[c] != 0
			var s := h[c] if land else 0.0
			if in_lake:
				s = float(m.lakes[_lake_id[c] - 1].level)
			if pts.size() > 0:
				s = minf(s, pts[pts.size() - 1].y)
			pts.append(Vector3(_cx(c), s, _cz(c)))
			flows.append(_flow[c] if land else 0.0)
			areas.append(_area[c])
			if visited[c] == 1:
				joins = river_of[c]
				break
			if not land or in_lake:
				break
			visited[c] = 1
			river_of[c] = m.rivers.size()
			c = _recv[c]
			if c < 0:
				break
		if pts.size() < 2:
			continue
		var river := _smooth_river(pts, flows, areas, mean_runoff)
		river.joins = joins
		river.kind = RIVER
		_floodplain(river)
		_meander(river, m.rivers.size())
		m.rivers.append(river)
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
	var scars: Array[Dictionary] = []
	for k in m.rivers.size():
		scars.append_array(_scars(m.rivers[k], k))
	m.rivers.append_array(scars)
	for river in m.rivers:
		river.erase("offsets")


enum { RIVER, OXBOW, SCAR }   ## River kinds: flowing (or dry) river, oxbow lake, meander scar.

const STEP := 24.0   ## Spacing of river centreline points (m).


# The D8 path zigzags cell to cell: resample it evenly, smooth it into a
# flowing line, then size the channel from the flow (past flow for dry beds).
func _smooth_river(pts: PackedVector3Array, flows: PackedFloat32Array, areas: PackedFloat32Array, past_runoff: float) -> Dictionary:
	var arc := PackedFloat32Array([0.0])
	for k in range(1, pts.size()):
		arc.append(arc[k - 1] + Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length())
	var total := arc[arc.size() - 1]
	var count := maxi(int(total / STEP), 1) + 1
	var sp := PackedVector3Array()
	var sq := PackedFloat32Array()
	var sa := PackedFloat32Array()
	var j := 0
	for k in count:
		var s := total * k / (count - 1) if count > 1 else 0.0
		while j < arc.size() - 2 and arc[j + 1] < s:
			j += 1
		var t := clampf((s - arc[j]) / maxf(arc[j + 1] - arc[j], 0.001), 0.0, 1.0) if arc.size() > 1 else 0.0
		var nxt := mini(j + 1, pts.size() - 1)
		sp.append(pts[j].lerp(pts[nxt], t))
		sq.append(lerpf(flows[j], flows[nxt], t))
		sa.append(lerpf(areas[j], areas[nxt], t))
	# smooth the path (ends fixed); heights keep falling downstream
	for _it in 10:
		var prev := sp.duplicate()
		for k in range(1, count - 1):
			var avg := (prev[k - 1] + prev[k] * 2.0 + prev[k + 1]) * 0.25
			sp[k] = Vector3(avg.x, prev[k].y, avg.z)
	for k in range(1, count):
		sp[k].y = minf(sp[k].y, sp[k - 1].y)
	var hw := PackedFloat32Array()
	var depth := PackedFloat32Array()
	var wet := PackedByteArray()
	var speed := PackedFloat32Array()
	for k in count:
		# flow speed from the slope of the water surface (faster down rapids)
		var a := maxi(k - 3, 0)
		var b := mini(k + 3, count - 1)
		var run := maxf(STEP * (b - a), 1.0)
		var drop := sp[a].y - sp[b].y
		speed.append(clampf(0.4 + 10.0 * sqrt(maxf(drop, 0.0) / run), 0.3, 4.0))
		var q_past := sa[k] * past_runoff
		var q := maxf(sq[k], 0.0)
		var is_wet := q >= 0.04
		var qw := maxf(q if is_wet else q_past, q_past * 0.6)
		hw.append(clampf(6.0 * sqrt(qw) + 4.0, 4.0, 120.0))
		depth.append(clampf(0.8 * pow(maxf(qw, 0.05), 0.35) + 0.8, 0.8, 8.0))
		wet.append(1 if is_wet else 0)
	return {"points": sp, "half_width": hw, "depth": depth, "flow": sq, "wet": wet, "speed": speed}


# Big rivers lay down flat valley floors: within a few channel widths of the
# river (more for bigger rivers) the ground is brought down to just above the
# water, rising gently toward the valley sides. This is where meanders, oxbow
# lakes and scars have room.
func _floodplain(river: Dictionary) -> void:
	var pts: PackedVector3Array = river.points
	var hw: PackedFloat32Array = river.half_width
	var h := m.height
	for k in range(0, pts.size(), 2):
		if hw[k] < 7.0 or _lake_at(pts[k]) :
			continue
		var width := clampf(hw[k] * 14.0, 150.0, 1500.0)
		var g := m.to_grid(pts[k].x, pts[k].z)
		var reach := ceili(width * 2.2 / cell)
		var cx := roundi(g.x)
		var cy := roundi(g.y)
		for y in range(maxi(cy - reach, 1), mini(cy + reach, n - 2) + 1):
			for x in range(maxi(cx - reach, 1), mini(cx + reach, n - 2) + 1):
				var i := y * n + x
				if not _land(i) or _lake_id[i] != 0:
					continue
				var d := Vector2(_cx(i) - pts[k].x, _cz(i) - pts[k].z).length() / width
				if d > 2.2:
					continue
				# flat near the river, curving up to meet the valley sides (by 2.2
				# widths the curve is well above most hills, so no edge shows)
				h[i] = minf(h[i], pts[k].y + 1.0 + width * (0.01 * d + 0.12 * d * d * d))


func _lake_at(p: Vector3) -> bool:
	var g := m.to_grid(p.x, p.z)
	return _lake_id[clampi(roundi(g.y), 0, n - 1) * n + clampi(roundi(g.x), 0, n - 1)] != 0


# Rivers wind: the centreline swings side to side in loops, a wavelength of
# about eleven channel widths and an amplitude near a third of that, but only
# as far as the valley floor is flat and wide: the swing is limited to where
# the ground on both sides stays within a few metres of the water. So rivers
# meander across floodplains and run straight in narrow valleys. The offsets
# are kept for _scars().
func _meander(river: Dictionary, index: int) -> void:
	var pts: PackedVector3Array = river.points
	var hw: PackedFloat32Array = river.half_width
	var count := pts.size()
	var offsets := PackedFloat32Array()
	offsets.resize(count)
	river.offsets = offsets
	if count < 8:
		return
	var total := STEP * (count - 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed_for("meander:%d" % index)
	var phase := rng.randf() * TAU
	var phase2 := rng.randf() * TAU
	var theta := 0.0
	var out := pts.duplicate()
	var amps := PackedFloat32Array()
	var thetas := PackedFloat32Array()
	var normals := PackedVector2Array()
	for k in count:
		var lam := clampf(hw[k] * 22.0, 140.0, 1400.0)
		theta += STEP / lam * TAU
		thetas.append(theta)
		var a := maxi(k - 4, 0)
		var b := mini(k + 4, count - 1)
		var t := Vector2(pts[b].x - pts[a].x, pts[b].z - pts[a].z).normalized()
		var nrm := Vector2(-t.y, t.x)
		normals.append(nrm)
		var s := STEP * k
		var taper := smoothstep(0.0, lam * 0.6, s) * smoothstep(0.0, lam * 0.6, total - s)
		var want := 0.4 * lam * taper
		# how far the floor stays flat on both sides
		var room := 0.0
		while room < want:
			var d := room + STEP * 0.5
			var p0 := Vector2(pts[k].x, pts[k].z)
			var limit := pts[k].y + 4.0 + 0.04 * d
			if m.height_at(p0.x + nrm.x * (d + hw[k]), p0.y + nrm.y * (d + hw[k])) > limit \
					or m.height_at(p0.x - nrm.x * (d + hw[k]), p0.y - nrm.y * (d + hw[k])) > limit:
				break
			room = d
		amps.append(minf(want, room))
	# the swing changes slowly along the river: a running minimum, then a blur
	var env := amps.duplicate()
	var win := 6
	for k in count:
		var lo := amps[k]
		for j in range(maxi(k - win, 0), mini(k + win, count - 1) + 1):
			lo = minf(lo, amps[j])
		env[k] = lo
	for _it in 4:
		var prev := env.duplicate()
		for k in range(1, count - 1):
			env[k] = (prev[k - 1] + prev[k] * 2.0 + prev[k + 1]) * 0.25
	for k in count:
		var off := env[k] * (sin(thetas[k] + phase) + 0.25 * sin(2.3 * thetas[k] + phase2))
		offsets[k] = off
		out[k] = pts[k] + Vector3(normals[k].x * off, 0.0, normals[k].y * off)
	river.points = out
	river.offsets = offsets


# Where a river's bends are biggest, the bends it used to have: arcs beside
# each big bend, further out, where the channel ran before it migrated.
# Usually a shallow dry scar (sometimes two or three, like scroll bars); the
# outermost is sometimes still holding water, an oxbow lake.
func _scars(river: Dictionary, index: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var pts: PackedVector3Array = river.points
	var offsets: PackedFloat32Array = river.offsets
	var hw: PackedFloat32Array = river.half_width
	var dep: PackedFloat32Array = river.depth
	var wet: PackedByteArray = river.wet
	var count := pts.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed_for("scars:%d" % index)
	for k in range(2, count - 2):
		var o := offsets[k]
		if absf(o) < 30.0 or absf(o) < absf(offsets[k - 1]) or absf(o) < absf(offsets[k + 1]):
			continue   # only at the apex of a large bend
		if rng.randf() > 0.6:
			continue
		var lam := clampf(hw[k] * 22.0, 140.0, 1400.0)
		var half := maxi(int(lam * 0.22 / STEP), 2)
		var side := signf(o)
		var g := m.to_grid(pts[k].x, pts[k].z)
		var arid := _arid[clampi(roundi(g.y), 0, n - 1) * n + clampi(roundi(g.x), 0, n - 1)]
		var rings := rng.randi_range(1, 3)
		for ring in rings:
			var shift := absf(o) * (0.55 + 0.45 * ring) + hw[k] * 1.5
			var oxbow := ring == rings - 1 and wet[k] == 1 and rng.randf() < 0.6 * (1.0 - arid)
			var sp := PackedVector3Array()
			var shw := PackedFloat32Array()
			var sd := PackedFloat32Array()
			var level := pts[k].y - (0.3 if oxbow else 0.0)
			for q in range(maxi(k - half, 1), mini(k + half, count - 2) + 1):
				var a := pts[q - 1]
				var b := pts[q + 1]
				var t := Vector2(b.x - a.x, b.z - a.z).normalized()
				var nrm := Vector2(-t.y, t.x) * side
				# the old channel: the bend pushed further out, rounding off at its ends
				var u := float(q - (k - half)) / float(2 * half)
				var bulge := sin(PI * u)
				sp.append(Vector3(pts[q].x + nrm.x * shift * bulge, level, pts[q].z + nrm.y * shift * bulge))
				shw.append(hw[k] * (0.8 if oxbow else 0.7) * sqrt(bulge) + 0.5)
				sd.append(dep[k] * (0.8 if oxbow else 0.35) * sqrt(bulge))
			if sp.size() < 3:
				continue
			var spd := PackedFloat32Array()
			spd.resize(sp.size())
			var w := PackedByteArray()
			w.resize(sp.size())
			w.fill(1 if oxbow else 0)
			out.append({"points": sp, "half_width": shw, "depth": sd, "speed": spd, "wet": w,
					"flow": spd, "kind": OXBOW if oxbow else SCAR, "joins": -1})
	return out


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
