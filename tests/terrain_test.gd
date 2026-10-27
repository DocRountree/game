extends SceneTree
## Headless tests of the world bake: determinism, lakes fed by rivers, rivers
## running downhill, land types, the cache round trip.
##
##   godot --headless --path . -s res://tests/terrain_test.gd

var _failures := 0


func _initialize() -> void:
	var cfg := WorldConfig.new()
	cfg.world_seed = 7
	var t := Time.get_ticks_msec()
	var a := WorldBake.new(cfg, 256).run()
	var bake_ms := Time.get_ticks_msec() - t
	var b := WorldBake.new(cfg, 256).run()
	_check(a.height == b.height and a.rivers.size() == b.rivers.size() and a.network().segments == b.network().segments
			and a.lakes.size() == b.lakes.size(), "same seed, same world (256 cells in %d ms)" % bake_ms)
	var cfg2 := WorldConfig.new()
	cfg2.world_seed = 8
	var c := WorldBake.new(cfg2, 256).run()
	_check(a.height != c.height, "a different seed gives a different world")

	_check(a.height_at(0.0, 0.0) < -5.0, "open water at the origin, where the player starts")
	var kinds := {}
	for lm in a.landmasses:
		kinds[lm.kind] = true
	_check(kinds.has(Landmass.Kind.VOLCANIC_CHAIN) and kinds.has(Landmass.Kind.ARCHIPELAGO),
			"volcanic chains and archipelagos in the layout (%s)" % [kinds.keys()])

	# lakes and rivers over several worlds
	var lakes := 0
	var fed := true
	var downhill := true
	var wet := 0
	var dry := 0
	var rock_on_volcanoes := true
	for s in [7, 8, 11, 12]:
		var cfg_s := WorldConfig.new()
		cfg_s.world_seed = s
		var w := a if s == 7 else (c if s == 8 else WorldBake.new(cfg_s, 384).run())
		for lake in w.lakes:
			lakes += 1
			fed = fed and int(lake.inflows) >= 1 and float(lake.level) <= float(lake.full_level) + 0.01
		for river in w.rivers:
			if river.kind != WorldBake.RIVER:
				continue
			var pts: PackedVector3Array = river.points
			for k in range(1, pts.size()):
				downhill = downhill and pts[k].y <= pts[k - 1].y + 0.001
			for v in river.wet:
				if v:
					wet += 1
				else:
					dry += 1
		for i in w.n * w.n:
			if w.owner[i] > 0 and w.landmasses[w.owner[i] - 1].kind == Landmass.Kind.VOLCANIC_CHAIN \
					and w.height[i] > 10.0 and w.material[i] != WorldMaps.Ground.ROCK:
				rock_on_volcanoes = false
	_check(lakes > 0 and fed, "every lake is fed by a river, wet or dry (%d lakes)" % lakes)
	_check(downhill, "rivers only run downhill")
	_check(wet > 0 and dry > 0, "some riverbeds carry water and some are dry (%d wet, %d dry points)" % [wet, dry])
	_check(rock_on_volcanoes, "volcanic islands are rock")
	var kinds_seen := {}
	var tributaries := 0
	for river in a.rivers:
		kinds_seen[river.kind] = true
		if river.joins >= 0:
			tributaries += 1
	_check(kinds_seen.has(WorldBake.OXBOW) or kinds_seen.has(WorldBake.SCAR), "meander scars and oxbow lakes beside the bends (%s)" % [kinds_seen.keys()])
	_check(tributaries > 5, "rivers have tributaries (%d)" % tributaries)

	var path := "user://test_world.wmap"
	a.save(path)
	var loaded := WorldMaps.load_from(path, WorldBake.VERSION)
	_check(loaded != null and loaded.height == a.height and loaded.network().segments == a.network().segments
			and loaded.lakes.size() == a.lakes.size() and loaded.rivers.size() == a.rivers.size(),
			"the bake survives a save and load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(_shader_compiles("res://src/systems/terrain/terrain_levels.glsl"), "terrain compute shader compiles to SPIR-V")

	print("\n%s: %d failure(s)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures else 0)


func _shader_compiles(path: String) -> bool:
	var file: RDShaderFile = load(path)
	return file != null and file.get_spirv().compile_error_compute == ""


func _check(ok: bool, what: String) -> void:
	print(("  ok    " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
