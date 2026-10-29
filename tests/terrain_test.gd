extends SceneTree
## Headless tests of the generated world (WorldData, from tools/gen_world.py):
## the heights load and decode, the mips agree, the islands are there, the
## rivers run downhill in their carved beds, the trees stand on land and the
## player starts on a beach with the boat in open water.
## Run: godot --headless --path . -s res://tests/terrain_test.gd

var _failures := 0


func _initialize() -> void:
	var t := Time.get_ticks_msec()
	var w := WorldData.get_world()
	_check(w != null, "the generated world loads (%d ms)" % (Time.get_ticks_msec() - t))
	if w == null:
		_finish()
		return
	_check(is_equal_approx(w.size, 20480.0) and w.texels == 8192 and is_equal_approx(w.spacing, 2.5),
			"20 x 20 km at 2.5 m (%.0f m, %d samples)" % [w.size, w.texels])

	# mip 1 is the mean of 2 x 2 samples of mip 0 (the GPU reads both)
	var n := w.texels
	var worst := 0.0
	for k in 200:
		var ix := (k * 7919) % (n / 2)
		var iz := (k * 104729) % (n / 2)
		var mean := (w.sample(ix * 2, iz * 2) + w.sample(ix * 2 + 1, iz * 2) + w.sample(ix * 2, iz * 2 + 1) + w.sample(ix * 2 + 1, iz * 2 + 1)) * 0.25
		var o := n * n + iz * (n / 2) + ix
		var m1 := (w.hi[o] * 256 + w.lo[o]) * w.h_scale + w.h_min
		worst = maxf(worst, absf(m1 - mean))
	_check(worst < 0.05, "mip 1 is the mean of mip 0 (worst %.3f m)" % worst)

	# the islands: a main island with a range, plenty of land, deep sea around
	var hmax := -INF
	var land := 0
	for iz in range(0, n, 8):
		for ix in range(0, n, 8):
			var h := w.sample(ix, iz)
			hmax = maxf(hmax, h)
			land += 1 if h > 0.0 else 0
	var km2 := land * 64.0 * w.spacing * w.spacing / 1e6
	_check(hmax > 500.0 and hmax < 1000.0, "mountains of game scale: the highest peak %.0f m" % hmax)
	_check(km2 > 40.0 and km2 < 160.0, "land %.1f km2 of the 420 km2 world" % km2)
	var kinds := {}
	for lm in w.landmasses:
		kinds[lm.kind] = kinds.get(lm.kind, 0) + 1
	_check(kinds.get("main_island", 0) == 1 and kinds.get("peripheral_island", 0) == 1 and kinds.get("islet", 0) >= 50
			and kinds.get("volcano", 0) >= 5 and kinds.get("southern_island", 0) >= 5, "main and peripheral islands, an archipelago, a volcanic chain and a southern group (%s)" % [kinds])

	# rivers: downhill, to the sea or into another river, lying in their carved beds
	var downhill := true
	var to_sea := 0
	var in_bed := 0
	var banks_hold := 0
	var checked := 0
	for ri in w.rivers.size():
		var r: Dictionary = w.rivers[ri]
		var pts: PackedVector3Array = r.points
		var hw: PackedFloat32Array = r.half_width
		for k in range(1, pts.size()):
			downhill = downhill and pts[k].y <= pts[k - 1].y + 0.001
		if r.joins < 0:
			to_sea += 1
			downhill = downhill and pts[pts.size() - 1].y <= 0.001
		for k in range(4, pts.size() - 4, 3):
			var p := pts[k]
			if w.height_at(p.x, p.z) < 0.0:
				continue   # (out in the estuary)
			if pts[k - 4].y - pts[k + 4].y > 2.0 or r.depth[k] < 0.4:
				continue   # (a waterfall, where the water falls past the lip; a head, where it is a trickle)
			if _on_island(w, p):
				continue   # (the river parts round an island there)
			checked += 1
			in_bed += 1 if w.height_at(p.x, p.z) < p.y - 0.2 else 0
			if _near_other(w, ri, p, hw[k] * 3.0):
				banks_hold += 1   # (where rivers meet, the other's channel is beside it)
				continue
			# the ground beside the channel stands above the water: it never floats
			var d := Vector2(pts[k + 1].x - pts[k - 1].x, pts[k + 1].z - pts[k - 1].z).normalized()
			var side := Vector2(-d.y, d.x) * hw[k] * 1.6
			var ok := w.height_at(p.x + side.x, p.z + side.y) > p.y - 0.15 and w.height_at(p.x - side.x, p.z - side.y) > p.y - 0.15
			banks_hold += 1 if ok else 0
	_check(w.rivers.size() >= 4 and to_sea == 1, "one river system: %d rivers, %d reaching the sea" % [w.rivers.size(), to_sea])
	_check(downhill, "rivers only run downhill, to the sea")
	_check(checked > 100 and in_bed > checked * 0.97, "the water lies in a bed below it (%d of %d points)" % [in_bed, checked])
	var dry_isles := 0
	for i: Dictionary in w.islands:
		dry_isles += 1 if w.height_at(i.x, i.z) > Water.surface_height(i.x, i.z) + 0.3 else 0
	_check(w.islands.size() >= 1 and dry_isles == w.islands.size(),
			"the river parts round islands standing out of it (%d of %d)" % [dry_isles, w.islands.size()])
	_check(banks_hold > checked * 0.95, "banks rise above the water on both sides (%d of %d points)" % [banks_hold, checked])

	# waterfalls on the mountain streams: cascades of several risers, and
	# steep reaches coming down in steps
	var cascades := 0
	var tall := 0
	var risers := 0
	for r in w.rivers:
		var pts: PackedVector3Array = r.points
		for c: Vector2i in r.cascades:
			cascades += 1
			tall += 1 if pts[c.x].y - pts[c.y].y >= 5.0 else 0
		var ris: PackedFloat32Array = r.riser
		for k in range(1, ris.size()):
			risers += 1 if ris[k] >= 0.0 and ris[k - 1] < 0.0 else 0
	_check(cascades >= 5 and tall == cascades and risers > cascades * 4,
			"%d waterfalls down the mountainsides, %d risers in all (cascades and step-pools)" % [cascades, risers])
	# down a riser the water lies on the rock: the rock never shows through it
	var mesh := RiverRibbons.build(w.rivers, w)
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var cu: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var on_riser := 0
	var through := 0
	for i in v.size():
		if cu[i * 4] >= 0.0 and absf(uv[i].x) < 0.8:
			on_riser += 1
			through += 1 if w.surface_at(v[i].x, v[i].z) > v[i].y + 0.05 else 0
	_check(on_riser > 1000 and through < on_riser / 100,
			"water lies on the rock down the risers (rock through it at %d of %d points)" % [through, on_riser])

	# confluences: each tributary meets its river running the same way
	var aligned := 0
	var tribs := 0
	for r in w.rivers:
		if r.joins < 0:
			continue
		tribs += 1
		var pts: PackedVector3Array = r.points
		var end := pts[pts.size() - 1]
		var before := pts[maxi(pts.size() - 6, 0)]
		var main: PackedVector3Array = w.rivers[r.joins].points
		var best := 0
		for k in main.size():
			if Vector2(main[k].x - end.x, main[k].z - end.z).length() < Vector2(main[best].x - end.x, main[best].z - end.z).length():
				best = k
		var md := Vector2(main[mini(best + 3, main.size() - 1)].x - main[maxi(best - 3, 0)].x, main[mini(best + 3, main.size() - 1)].z - main[maxi(best - 3, 0)].z).normalized()
		var td := Vector2(end.x - before.x, end.z - before.z).normalized()
		aligned += 1 if md.dot(td) > 0.5 else 0
	_check(tribs > 0 and aligned == tribs, "tributaries join their rivers flowing downstream (%d of %d)" % [aligned, tribs])

	# trees: on dry land, off the beaches and out of the rivers
	var dry := 0
	var count := w.tree_count()
	for i in range(0, count, maxi(count / 2000, 1)):
		var tr := w.tree(i)
		dry += 1 if w.height_at(tr.x, tr.z) > 2.0 else 0
	_check(count > 20000 and dry >= mini(count, 2000) * 0.99, "%d stand-in trees, all on dry land" % count)

	# the start: a beach, with the boat in open water nearby
	var gs := w.height_at(w.spawn.x, w.spawn.y)
	var gb := w.height_at(w.boat.x, w.boat.y)
	_check(gs > 0.5 and gs < 8.0 and gb < -5.0 and w.spawn.distance_to(w.boat) < 400.0,
			"you start on a beach (%.1f m up) with the boat %.0f m off in %.1f m of water" % [gs, w.spawn.distance_to(w.boat), -gb])
	_finish()


func _near_other(w: WorldData, ri: int, p: Vector3, reach: float) -> bool:
	for j in w.rivers.size():
		if j == ri:
			continue
		for q: Vector3 in w.rivers[j].points:
			if Vector2(q.x - p.x, q.z - p.z).length() < reach:
				return true
	return false


func _on_island(w: WorldData, p: Vector3) -> bool:
	for i: Dictionary in w.islands:
		var a: float = ((p.x - i.x) * i.dx + (p.z - i.z) * i.dz) / (i.length * 0.5)
		var b: float = (-(p.x - i.x) * i.dz + (p.z - i.z) * i.dx) / (i.width * 2.0)
		if a * a + b * b < 1.3:
			return true
	return false


func _finish() -> void:
	print("\n%s: %d failure(s)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures else 0)


func _check(ok: bool, what: String) -> void:
	print(("  ok    " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
