extends SceneTree
## Headless checks for the groundwork systems (water queries, inventory,
## boat specs and stations, trackers, clock events, character traits). Exit
## code 0 = pass.
##
##   godot --headless --path . -s res://tests/systems_test.gd

var _failures := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var world: Node3D = load("res://src/world/open_ocean/open_ocean.tscn").instantiate()
	root.add_child(world)
	await _frames(2)
	var player: Player = world.get_node("Player")
	var boat: Boat = world.get_node("Boat")
	var clock: GameClock = world.get_node("Clock")
	var camera: PlayerCamera = world.get_node("Camera")
	var events := root.get_node("Events")

	# water: the ocean answers everywhere; a lake with higher priority takes over inside it
	var ocean_here := Water.body_at(0.0, 0.0)
	var sample := Water.sample_at(Vector3(10.0, -5.0, 10.0))
	_check(ocean_here is Ocean and sample.body_kind == WaterBody.Kind.OCEAN and sample.biome_id == &"open_ocean"
			and sample.salinity_ppt == 35.0 and sample.depth > 3.0 and sample.depth < 7.0,
			"Water.sample_at() describes the open ocean (depth %.1f m)" % sample.depth)
	var lake := _TestLake.new()
	lake.kind = WaterBody.Kind.LAKE
	lake.priority = 10
	lake.salinity_ppt = 0.0
	world.add_child(lake)
	_check(Water.body_at(0.0, 0.0) == lake and Water.body_at(100.0, 0.0) is Ocean
			and lake.density() < ocean_here.density(), "a fresher, higher-priority lake overrides the ocean inside it")
	lake.queue_free()
	await process_frame

	# inventory: stacking, overflow, filters, save/load
	var fish := ItemDef.new()
	fish.id = &"sardine"
	fish.max_stack = 5
	fish.tags = [&"catch"]
	var inv := Inventory.new()
	inv.capacity = 2
	var left := inv.add(ItemStack.new(fish, 12))
	_check(left != null and left.count == 2 and inv.count_of(fish) == 10 and inv.free_slots() == 0,
			"inventory stacks up to max_stack and returns the overflow")
	var only_tools := Inventory.new()
	only_tools.accepts_tags = [&"tool"]
	_check(only_tools.add(ItemStack.new(fish)) != null, "inventory filters by tag")
	inv.free()
	only_tools.free()
	_check(player.left_hand.capacity == 1 and player.right_hand.capacity == 1 and player.knapsack.capacity == 8,
			"player has two hands and a knapsack")
	var snorkel := ItemDef.new()
	snorkel.stats = {&"breath_seconds": 40.0}
	var base := player.breath_capacity()
	player.right_hand.add(ItemStack.new(snorkel))
	_check(player.breath_capacity() == base + 40.0 and player.held(1).item == snorkel, "held gear changes breath capacity")
	player.right_hand.take(0)

	# boats: spec drives the body, stations and hold exist
	_check(boat.spec.id == &"small_motorboat" and boat.mass == boat.spec.mass
			and boat.cargo.capacity == boat.spec.cargo_slots, "boat reads its BoatSpec (mass, hold size)")
	_check(boat.helm and boat.station(BoatStation.Kind.PERCH) and boat.station(BoatStation.Kind.CARGO).inventory == boat.cargo
			and boat.station(BoatStation.Kind.RESEARCH) == null, "boat stations: helm, perch and hold, no research bench")

	# clock: rolling past midnight counts a day and tells the bus
	var days_seen := []
	events.day_changed.connect(func(d: int) -> void: days_seen.append(d))
	var start_day := clock.day
	var start_total := clock.total_hours
	clock.time_of_day = 23.5
	clock.advance(1.0)
	_check(clock.day == start_day + 1 and days_seen == [start_day + 1] and absf(clock.total_hours - start_total - 1.0) < 1e-6,
			"clock rolls over midnight, counts game hours and emits day_changed")
	clock.time_of_day = 12.0

	# sunsets: each day draws its own air, reproducibly
	var atmosphere: Atmosphere = world.get_node("Atmosphere")
	var air := []
	for d in [1, 2, 1]:
		atmosphere._vary_air(d)
		air.append([atmosphere.mie_scattering, atmosphere.strat_scattering, atmosphere.twilight_glow])
	atmosphere._vary_air(clock.day)
	_check(air[0] != air[1] and air[0] == air[2], "sunset air varies by day and repeats for the same day")

	# exploration: cells around the player are revealed, and survive a save/load
	var explore: ExplorationTracker = world.get_node("Exploration")
	var revealed := explore.explored.size()
	var saved := explore.to_dict()
	explore.from_dict(saved)
	_check(revealed > 50 and explore.explored.size() == revealed and explore.is_explored(player.global_position)
			and not explore.is_explored(Vector3(5000, 0, 5000)), "exploration reveals %d cells near the player" % revealed)

	# camera zoom narrows the field of view
	camera.zoom = 10.0
	var narrow := camera.fov
	camera.zoom = 1.0
	_check(narrow < 8.0 and absf(camera.fov - camera.base_fov) < 0.01, "camera zoom x10 narrows the view to %.1f deg" % narrow)

	# characters: the generator is reproducible
	var a := RandomNumberGenerator.new()
	a.seed = 42
	var b := RandomNumberGenerator.new()
	b.seed = 42
	var ta := CharacterTraits.generate(a)
	var tb := CharacterTraits.generate(b)
	_check(ta.height == tb.height and ta.shirt_color == tb.shirt_color and ta.height > 1.4, "character traits generate reproducibly")

	# species filters
	var crab := SpeciesDef.new()
	crab.catch_methods = SpeciesDef.Catch.TRAP | SpeciesDef.Catch.NET
	crab.active_hours = Vector2(20.0, 4.0)
	crab.depth_range = Vector2(0.0, 30.0)
	var biome := BiomeDef.new()
	biome.species = [crab]
	_check(crab.can_catch_with(SpeciesDef.Catch.TRAP) and not crab.can_catch_with(SpeciesDef.Catch.ROD)
			and biome.species_for(10.0, 23.0, WaterBody.Kind.OCEAN).size() == 1
			and biome.species_for(10.0, 12.0, WaterBody.Kind.OCEAN).is_empty()
			and biome.species_for(10.0, 23.0, WaterBody.Kind.LAKE).is_empty(), "species filter by gear, hour, depth and water")

	# stats: sinking counts time under water
	await _frames(240)
	_check(player.stats.seconds_in_water > 1.0 and player.stats.seconds_submerged > 0.0
			and player.stats.max_depth_m > 0.0 and player.stats.waters_visited.has(WaterBody.Kind.OCEAN)
			and player.stats.waters_visited.has(WaterBody.Kind.LAKE),
			"player stats track time in and under water, and both waters visited (%.1f s in, %.1f s under, %.1f m, %s)" % [player.stats.seconds_in_water,
			player.stats.seconds_submerged, player.stats.max_depth_m, player.stats.waters_visited])

	print("\n%s: %d failure(s)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures else 0)


class _TestLake extends WaterBody:
	func contains_point(x: float, z: float) -> bool:
		return Vector2(x, z).length() < 50.0


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _check(ok: bool, what: String) -> void:
	print(("  ok    " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
