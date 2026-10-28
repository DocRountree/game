class_name RiverGraph
extends RefCounted
## The drainage network, made first, and the land made from it (after
## Génevaux et al. 2013, "Terrain Generation Using Procedural Models Based on
## Hydrology"). Rivers are not traced down a finished terrain; the terrain is
## built around them, so every river lies exactly on its valley floor and
## always falls toward the sea.
##
## 1. Growth: river mouths are scattered along every coast; each mouth's
##    network grows inland node by node (a step of a few hundred metres),
##    continuing and sometimes branching, never crowding another node. Some
##    basins grow more vigorously than others and claim more land, so a few
##    rivers get big while most stay small, as on real coasts. Land the
##    growth never reached gets short streams from the nearest node.
## 2. Elevation: the drained area of each node is the land its upstream nodes
##    cover; channel slope is the steady state of stream-power erosion,
##    uplift / sqrt(area) (steep little headwaters in the mountains, gentle
##    big rivers), summed up from the mouth.
## 3. Paths: the network splits into streams (each follows its biggest
##    branch upstream), smoothed into flowing curves.
## 4. Land: every point takes the elevation of the nearest stream, plus a
##    hillslope rising with distance from it (steeper where the land rises
##    faster); big gentle rivers sit on a flat floodplain first. Ridges form
##    where two streams' hillslopes meet.

const STEP := 300.0          ## Distance between network nodes (m).
const MIN_GAP := 0.72        ## No two nodes closer than this many steps.
const MOUTH_GAP := 2.2       ## Mouths at least this many steps apart.
const BRANCH := 0.32         ## Chance a node also sends out a side branch, times its basin's vigor.
const SMOOTH := 3            ## Corner-cutting passes on each stream.

# nodes
var px := PackedFloat32Array()
var pz := PackedFloat32Array()
var parent := PackedInt32Array()
var first_child := PackedInt32Array()
var next_sibling := PackedInt32Array()
var owner := PackedInt32Array()          # landmass id + 1
var area := PackedFloat32Array()         # drained area (m^2)
var elev := PackedFloat32Array()         # channel elevation (m)
var mouth_dir := PackedVector2Array()    # for mouths: the way out to sea

## Streams: each a Dictionary with "points" (PackedVector2Array, downstream
## order, smoothed), "elev", "area", "fp" (floodplain half width, m) per
## point, "joins" (index of the stream it flows into, -1 at the sea) and
## "mouth" (Vector2 just offshore, for streams that reach the sea).
var streams: Array[Dictionary] = []

var _b: WorldBake
var _rng := RandomNumberGenerator.new()
var _nodes_per := PackedInt32Array()     # nodes per landmass
var _bucket_head := PackedInt32Array()
var _bucket_next := PackedInt32Array()
var _buckets := 0


func _init(bake: WorldBake) -> void:
	_b = bake
	_rng.seed = bake.config.seed_for("river network")


# --- 1. growth -------------------------------------------------------------------

func grow() -> void:
	_buckets = ceili(_b.size / STEP) + 1
	_bucket_head.resize(_buckets * _buckets)
	_bucket_head.fill(-1)
	_nodes_per.resize(_b.landmasses.size() + 1)
	var heap := Heap.new()
	var vigor := PackedFloat32Array()
	var dirs := PackedVector2Array()
	var cost := PackedFloat32Array()
	# mouths, scattered along the coasts in random order
	var coast := PackedInt32Array()
	var n := _b.n
	for y in range(2, n - 2):
		for x in range(2, n - 2):
			var i := y * n + x
			if _b._is_land[i] == 1 and _b._dist[i] < _b.cell:
				coast.append(i)
	for k in range(coast.size() - 1, 0, -1):
		var r := _rng.randi_range(0, k)
		var t := coast[k]
		coast[k] = coast[r]
		coast[r] = t
	for i in coast:
		var p := Vector2(_b._cx(i), _b._cz(i))
		if _near(p, STEP * MOUTH_GAP, -1):
			continue
		var g := _inland(p)
		if g == Vector2.ZERO:
			continue
		var id := _add(p, -1, _b.m.owner[i])
		mouth_dir[id] = -g
		dirs.append(g)
		vigor.append(exp(_rng.randfn(0.0, 0.85)))
		cost.append(0.0)
		heap.push(0.0, id)
	# grow inland, cheapest first (cost = distance from the mouth / vigor)
	while not heap.empty():
		var i := heap.pop()
		var p := Vector2(px[i], pz[i])
		var g := _inland(p)
		var base := (dirs[i] * 0.6 + g * 0.4).normalized() if g != Vector2.ZERO else dirs[i]
		var a0 := base.angle() + _rng.randf_range(-0.35, 0.35)
		var made := 0
		for attempt in 4:
			var a := a0 + (attempt + 1) / 2 * 0.4 * (1.0 if attempt % 2 == 0 else -1.0)
			if _try_child(i, p, a, heap, vigor, dirs, cost):
				made += 1
				break
		if _rng.randf() < clampf(BRANCH * vigor[i], 0.08, 0.75):
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			for attempt in 3:
				var a := a0 + side * _rng.randf_range(0.6, 1.15)
				if _try_child(i, p, a, heap, vigor, dirs, cost):
					break
	_fill_gaps(n)
	# drained area: each node stands for its share of its landmass's land
	var land_cells := PackedInt32Array()
	land_cells.resize(_b.landmasses.size() + 1)
	for i in n * n:
		if _b._is_land[i] == 1:
			land_cells[_b.m.owner[i]] += 1
	area.resize(px.size())
	for i in px.size():
		area[i] = land_cells[owner[i]] * _b.cell * _b.cell / maxf(_nodes_per[owner[i]], 1.0)
	for i in range(px.size() - 1, -1, -1):   # children always come after parents
		if parent[i] >= 0:
			area[parent[i]] += area[i]


# Land the growth never reached (it got boxed in) gets short streams from
# the nearest node, so every hillside drains into a stream nearby.
func _fill_gaps(n: int) -> void:
	for _pass in 3:
		var cells := PackedInt32Array()
		var stride := maxi(int(STEP * 0.5 / _b.cell), 1)
		for y in range(2, n - 2, stride):
			for x in range(2, n - 2, stride):
				var i := y * n + x
				if _b._is_land[i] == 1 and _b._dist[i] > 60.0:
					cells.append(i)
		for k in range(cells.size() - 1, 0, -1):
			var r := _rng.randi_range(0, k)
			var t := cells[k]
			cells[k] = cells[r]
			cells[r] = t
		var added := 0
		for i in cells:
			var q := Vector2(_b._cx(i), _b._cz(i))
			if _near(q, STEP * 0.9, -1):
				continue
			var best := _nearest(q, STEP * 2.5, _b.m.owner[i])
			if best < 0:
				continue
			var p := Vector2(px[best], pz[best])
			if p.distance_to(q) > STEP * 1.3:
				q = p + (q - p).normalized() * STEP
				var gi := _grid(q)
				if gi < 0 or _b._is_land[gi] == 0 or _near(q, STEP * MIN_GAP, best):
					continue
			_add(q, best, owner[best])
			added += 1
		if added == 0:
			break


func _nearest(p: Vector2, r: float, own: int) -> int:
	var bx := int((p.x + _b.size * 0.5) / STEP)
	var by := int((p.y + _b.size * 0.5) / STEP)
	var reach := ceili(r / STEP)
	var best := -1
	var best_d := r * r
	for y in range(maxi(by - reach, 0), mini(by + reach, _buckets - 1) + 1):
		for x in range(maxi(bx - reach, 0), mini(bx + reach, _buckets - 1) + 1):
			var k := _bucket_head[y * _buckets + x]
			while k >= 0:
				var d := Vector2(px[k] - p.x, pz[k] - p.y).length_squared()
				if d < best_d and owner[k] == own:
					best_d = d
					best = k
				k = _bucket_next[k]
	return best


func _try_child(i: int, p: Vector2, a: float, heap: Heap, vigor: PackedFloat32Array,
		dirs: PackedVector2Array, cost: PackedFloat32Array) -> bool:
	var d := Vector2.from_angle(a)
	var len := STEP * _rng.randf_range(0.85, 1.15)
	var q := p + d * len
	var gi := _grid(q)
	if gi < 0 or _b._is_land[gi] == 0 or _b.m.owner[gi] != owner[i]:
		return false
	if _b._dist[gi] < 60.0 or _b._dist[gi] < _b._dist[_grid(p)] - 0.25 * STEP:
		return false   # stay inland, mostly heading away from the sea
	if _near(q, STEP * MIN_GAP, i) or _near((p + q) * 0.5, STEP * 0.45, i):
		return false
	var c := _add(q, i, owner[i])
	dirs.append(d)
	vigor.append(vigor[i])
	cost.append(cost[i] + len / vigor[i])
	heap.push(cost[c], c)
	return true


func _add(p: Vector2, par: int, own: int) -> int:
	var id := px.size()
	px.append(p.x)
	pz.append(p.y)
	parent.append(par)
	owner.append(own)
	first_child.append(-1)
	next_sibling.append(-1)
	mouth_dir.append(Vector2.ZERO)
	if par >= 0:
		next_sibling[id] = first_child[par]
		first_child[par] = id
	_nodes_per[own] += 1
	var b := _bucket(p)
	_bucket_next.append(_bucket_head[b])
	_bucket_head[b] = id
	return id


func _bucket(p: Vector2) -> int:
	var bx := clampi(int((p.x + _b.size * 0.5) / STEP), 0, _buckets - 1)
	var by := clampi(int((p.y + _b.size * 0.5) / STEP), 0, _buckets - 1)
	return by * _buckets + bx


func _near(p: Vector2, r: float, except: int) -> bool:
	var bx := int((p.x + _b.size * 0.5) / STEP)
	var by := int((p.y + _b.size * 0.5) / STEP)
	var reach := ceili(r / STEP)
	var r2 := r * r
	for y in range(maxi(by - reach, 0), mini(by + reach, _buckets - 1) + 1):
		for x in range(maxi(bx - reach, 0), mini(bx + reach, _buckets - 1) + 1):
			var k := _bucket_head[y * _buckets + x]
			while k >= 0:
				if k != except and Vector2(px[k] - p.x, pz[k] - p.y).length_squared() < r2:
					return true
				k = _bucket_next[k]
	return false


func _grid(p: Vector2) -> int:
	var x := int((p.x + _b.size * 0.5) / _b.cell)
	var y := int((p.y + _b.size * 0.5) / _b.cell)
	if x < 1 or y < 1 or x > _b.n - 2 or y > _b.n - 2:
		return -1
	return y * _b.n + x


# Away from the sea: up the distance-to-coast field.
func _inland(p: Vector2) -> Vector2:
	var i := _grid(p)
	if i < 0:
		return Vector2.ZERO
	var n := _b.n
	var d := _b._dist
	var g := Vector2(d[i + 1] - d[i - 1], d[i + n] - d[i - n])
	return g.normalized() if g.length_squared() > 1e-6 else Vector2.ZERO


# --- 2. elevation --------------------------------------------------------------------

func elevate() -> void:
	elev.resize(px.size())
	for i in px.size():
		var par := parent[i]
		if par < 0:
			elev[i] = 0.4
			continue
		var gi := _grid(Vector2(px[i], pz[i]))
		var up := _b._uplift[gi] if gi >= 0 else 0.1
		var len := Vector2(px[i] - px[par], pz[i] - pz[par]).length()
		var slope := minf(0.03 * up / sqrt(area[i] / 1e6), 0.45)
		elev[i] = elev[par] + len * slope


# --- 3. streams ------------------------------------------------------------------------

func make_streams() -> void:
	var count := px.size()
	# each node's biggest branch
	var main := PackedInt32Array()
	main.resize(count)
	main.fill(-1)
	for i in count:
		var par := parent[i]
		if par >= 0 and (main[par] < 0 or area[i] > area[main[par]]):
			main[par] = i
	var raw: Array[PackedInt32Array] = []
	var stream_of := PackedInt32Array()
	stream_of.resize(count)
	stream_of.fill(-1)
	for h in count:
		if first_child[h] >= 0:
			continue
		var path := PackedInt32Array([h])
		var c := h
		while true:
			var par := parent[c]
			if par < 0:
				break
			path.append(par)
			if main[par] != c:
				break   # a junction: par belongs to the stream it flows into
			c = par
		raw.append(path)
	# a stream ends at a junction (on another stream, maybe at its very
	# mouth) unless it is the one that owns its last node
	var at_junction := PackedByteArray()
	for path in raw:
		at_junction.append(1 if path.size() >= 2 and main[path[path.size() - 1]] != path[path.size() - 2] else 0)
	# biggest streams first, so each is smoothed before its tributaries snap to it
	var order := range(raw.size())
	var sizes := PackedFloat32Array()
	for k in raw.size():
		var path: PackedInt32Array = raw[k]
		sizes.append(area[path[path.size() - 2]] if at_junction[k] == 1 else area[path[path.size() - 1]])
	order.sort_custom(func(x: int, y: int) -> bool: return sizes[x] > sizes[y])
	var index_of := PackedInt32Array()
	index_of.resize(raw.size())
	for k in order.size():
		index_of[order[k]] = k
	for k in raw.size():
		var path: PackedInt32Array = raw[k]
		var owned := path.size() - 1 if at_junction[k] == 1 else path.size()
		for q in owned:
			stream_of[path[q]] = index_of[k]
	streams.clear()
	for k in order:
		var path: PackedInt32Array = raw[k]
		var last := path[path.size() - 1]
		var pts := PackedVector2Array()
		var el := PackedFloat32Array()
		var ar := PackedFloat32Array()
		for q in path.size():
			var i := path[q]
			pts.append(Vector2(px[i], pz[i]))
			el.append(elev[i])
			# (a tributary's last point is on the river it joins, but carries
			# only its own water)
			ar.append(area[path[q - 1]] if q == path.size() - 1 and at_junction[k] == 1 else area[i])
		var s := {"points": pts, "elev": el, "area": ar, "joins": -1, "mouth": Vector2.INF}
		if at_junction[k] == 1:
			s.joins = stream_of[last]
		else:
			s.mouth = Vector2(px[last], pz[last]) + mouth_dir[last] * STEP * 0.5
		_smooth(s)
		if s.joins >= 0:
			_snap(s, streams[s.joins])
		_floodplain_widths(s)
		streams.append(s)


# Corner cutting (Chaikin), ends fixed: a flowing curve through the nodes.
func _smooth(s: Dictionary) -> void:
	var pts: PackedVector2Array = s.points
	var el: PackedFloat32Array = s.elev
	var ar: PackedFloat32Array = s.area
	for _it in SMOOTH:
		if pts.size() < 3:
			break
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
	s.points = pts
	s.elev = el
	s.area = ar


# A tributary ends exactly on the (smoothed) stream it joins.
func _snap(s: Dictionary, main: Dictionary) -> void:
	var pts: PackedVector2Array = s.points
	var el: PackedFloat32Array = s.elev
	var end := pts[pts.size() - 1]
	var mp: PackedVector2Array = main.points
	var me: PackedFloat32Array = main.elev
	var best := INF
	var at := end
	var at_e := el[el.size() - 1]
	for k in mp.size() - 1:
		var ab := mp[k + 1] - mp[k]
		var t := clampf((end - mp[k]).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var c := mp[k] + ab * t
		var d := c.distance_squared_to(end)
		if d < best:
			best = d
			at = c
			at_e = lerpf(me[k], me[k + 1], t)
	pts[pts.size() - 1] = at
	el[el.size() - 1] = minf(at_e, el[el.size() - 2])
	s.points = pts
	s.elev = el


# Big, gentle rivers lie on wide flat floodplains (alluvial plains), wider
# the more land drains through them; steep ones in V-shaped valleys.
func _floodplain_widths(s: Dictionary) -> void:
	var pts: PackedVector2Array = s.points
	var el: PackedFloat32Array = s.elev
	var ar: PackedFloat32Array = s.area
	var fp := PackedFloat32Array()
	var c := pts.size()
	for k in c:
		var a := maxi(k - 2, 0)
		var b := mini(k + 2, c - 1)
		var run := 0.0
		for q in range(a, b):
			run += pts[q].distance_to(pts[q + 1])
		var slope := (el[a] - el[b]) / maxf(run, 1.0)
		var w := clampf(0.07 * sqrt(ar[k]) - 90.0, 0.0, 2600.0)
		fp.append(w * (1.0 - smoothstep(0.002, 0.015, slope)))
	s.fp = fp


# --- 4. land ------------------------------------------------------------------------------

var _sa := PackedVector2Array()   # segment ends
var _sb := PackedVector2Array()
var _se := PackedVector2Array()   # elevation at each end
var _sf := PackedVector2Array()   # floodplain half width at each end


## Heights for every land cell from the streams, scaled so each landmass
## reaches its peak (the streams' elevations scaled with it).
func build_land() -> void:
	for s in streams:
		var pts: PackedVector2Array = s.points
		var el: PackedFloat32Array = s.elev
		var fp: PackedFloat32Array = s.fp
		for k in pts.size() - 1:
			if pts[k].distance_squared_to(pts[k + 1]) < 1e-4:
				continue
			_sa.append(pts[k])
			_sb.append(pts[k + 1])
			_se.append(Vector2(el[k], el[k + 1]))
			_sf.append(Vector2(fp[k], fp[k + 1]))
	var n := _b.n
	var cell := _b.cell
	var count := n * n
	var near := PackedInt32Array()
	near.resize(count)
	near.fill(-1)
	var dist := PackedFloat32Array()
	dist.resize(count)
	dist.fill(INF)
	# seed the cells the streams run through
	for k in _sa.size():
		var len := _sa[k].distance_to(_sb[k])
		var steps := maxi(ceili(len / (cell * 0.5)), 1)
		for q in steps + 1:
			var p := _sa[k].lerp(_sb[k], float(q) / steps)
			var gi := _grid(p)
			if gi < 0:
				continue
			var d := _seg_dist(k, Vector2(_b._cx(gi), _b._cz(gi)))
			if d < dist[gi]:
				dist[gi] = d
				near[gi] = k
	# then spread the nearest segment over the land, two sweeps (vector
	# distance transform), re-measuring exactly at every cell
	var isl := _b._is_land
	for pass_dir in 2:
		var y0 := 1 if pass_dir == 0 else n - 2
		var y1 := n - 1 if pass_dir == 0 else 0
		var step := 1 if pass_dir == 0 else -1
		var offs := PackedInt32Array([-1, -n - 1, -n, -n + 1]) if pass_dir == 0 else PackedInt32Array([1, n + 1, n, n - 1])
		var y := y0
		while y != y1:
			var x := 1 if pass_dir == 0 else n - 2
			while x >= 1 and x <= n - 2:
				var i := y * n + x
				if isl[i] == 1:
					var c := Vector2(_b._cx(i), _b._cz(i))
					for o in offs:
						var k := near[i + o]
						if k >= 0 and k != near[i]:
							var d := _seg_dist(k, c)
							if d < dist[i]:
								dist[i] = d
								near[i] = k
				x += step
			y += step
	# heights: the stream's elevation, flat across its floodplain, then a
	# hillslope rising with distance (steeper where the land rises faster)
	var h := _b.m.height
	var raw_max := PackedFloat32Array()
	raw_max.resize(_b.landmasses.size() + 1)
	for i in count:
		if isl[i] == 0:
			continue
		var k := near[i]
		if k < 0:
			h[i] = 0.3 + _b._dist[i] * 0.05 * _b._uplift[i]
		else:
			var c := Vector2(_b._cx(i), _b._cz(i))
			var t := _seg_t(k, c)
			var e := lerpf(_se[k].x, _se[k].y, t)
			var fp := lerpf(_sf[k].x, _sf[k].y, t)
			var slope := 0.04 + 0.5 * _b._uplift[i]
			# (the floodplain leans very slightly toward the river, so water
			# on it drains into the channel)
			h[i] = e + dist[i] * 0.002 + maxf(0.0, dist[i] - fp) * slope
		raw_max[_b.m.owner[i]] = maxf(raw_max[_b.m.owner[i]], h[i])
	var scale := PackedFloat32Array()
	scale.resize(raw_max.size())
	for o in range(1, raw_max.size()):
		scale[o] = _b.landmasses[o - 1].peak / maxf(raw_max[o], 1.0)
	for i in count:
		if isl[i] == 0:
			continue
		var bank := 0.0
		if near[i] >= 0:
			bank = 1.2 * smoothstep(0.0, 40.0, dist[i])   # the floodplain stands a little above the water
		h[i] = maxf(h[i] * scale[_b.m.owner[i]] + bank, 0.3)
	for s in streams:
		var el: PackedFloat32Array = s.elev
		var pts: PackedVector2Array = s.points
		var gi := _grid(pts[0])
		var f := scale[_b.m.owner[gi]] if gi >= 0 else 1.0
		for k in el.size():
			el[k] *= f
		s.elev = el
	for i in px.size():
		elev[i] *= scale[owner[i]]


func _seg_t(k: int, p: Vector2) -> float:
	var ab := _sb[k] - _sa[k]
	return clampf((p - _sa[k]).dot(ab) / ab.length_squared(), 0.0, 1.0)


func _seg_dist(k: int, p: Vector2) -> float:
	var ab := _sb[k] - _sa[k]
	var t := clampf((p - _sa[k]).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(_sa[k] + ab * t)


# A binary min-heap of node ids by cost.
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
			var m := i
			if l < last and keys[l] < keys[m]:
				m = l
			if r < last and keys[r] < keys[m]:
				m = r
			if m == i:
				break
			_swap(i, m)
			i = m
		return top

	func _swap(a: int, b: int) -> void:
		var tk := keys[a]
		keys[a] = keys[b]
		keys[b] = tk
		var tv := vals[a]
		vals[a] = vals[b]
		vals[b] = tv
