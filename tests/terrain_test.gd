extends SceneTree
## Headless tests of the world bake from the painted maps: determinism, the
## layout, the main island's single river system running downhill, the
## biomes, and saving. Run: godot --headless --path . -s res://tests/terrain_test.gd

var _failures := 0


func _initialize() -> void:
	var cfg := WorldConfig.new()
	var t := Time.get_ticks_msec()
	var a := WorldBake.new(cfg, 400).run()
	var bake_ms := Time.get_ticks_msec() - t
	var b := WorldBake.new(cfg, 400).run()
	_check(a.height == b.height and a.rivers.size() == b.rivers.size() and a.network().segments == b.network().segments,
			"the same maps make the same world (400 cells in %d ms)" % bake_ms)
	_check(a.height_at(0.0, 0.0) < -2.0, "open water at the origin, where the player starts")

	var names := []
	for lm in a.landmasses:
		names.append(lm.name)
	_check(names == ["main_island", "peripheral_island", "main_archipelago", "volcanic_chain", "southern_archipelago"],
			"every landmass in the layout (%s)" % [names])
	var land := {}
	for i in a.n * a.n:
		if a.owner[i] > 0:
			land[a.owner[i]] = land.get(a.owner[i], 0) + 1
	_check(land.size() == 5, "every landmass has land (%s)" % [land])

	# the main island's rivers: one system, joined, running downhill to the sea
	var to_sea := 0
	var downhill := true
	for river in a.rivers:
		var pts: PackedVector3Array = river.points
		for k in range(1, pts.size()):
			downhill = downhill and pts[k].y <= pts[k - 1].y + 0.001
		if river.joins < 0:
			to_sea += 1
			downhill = downhill and pts[pts.size() - 1].y < 1.0
	_check(a.rivers.size() >= 2 and to_sea == 1, "one river system: %d rivers, %d reaching the sea" % [a.rivers.size(), to_sea])
	_check(downhill, "rivers only run downhill, to the sea")

	var biomes := {}
	for v in a.biome:
		biomes[v] = true
	var want := [WorldMaps.Biome.MESA, WorldMaps.Biome.PRAIRIE, WorldMaps.Biome.FOREST, WorldMaps.Biome.CORAL_REEF,
			WorldMaps.Biome.ROOT_MAZE, WorldMaps.Biome.KELP_FOREST, WorldMaps.Biome.ARCHIPELAGO,
			WorldMaps.Biome.VOLCANIC, WorldMaps.Biome.ISLAND]
	var all := true
	for w in want:
		all = all and biomes.has(w)
	_check(all, "every biome is on the map (%s)" % [biomes.keys()])
	_check(WorldMaps.biome_of_color(Color8(255, 115, 0)) == WorldMaps.Biome.MESA
			and WorldMaps.biome_of_color(Color.BLACK) == WorldMaps.Biome.NONE, "biome map colours are read back")

	var path := "user://test_world.wmap"
	a.save(path)
	var loaded := WorldMaps.load_from(path, WorldBake.VERSION)
	_check(loaded != null and loaded.height == a.height and loaded.biome == a.biome
			and loaded.rivers.size() == a.rivers.size(), "the bake survives a save and load")
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
