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
	Terrain.bake_resolution = 256   # a small world: quick to bake
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

	# the real clock node, ticked like the game does: a full day from noon
	var atmosphere_node: Atmosphere = world.get_node("Atmosphere")
	clock.time_of_day = 12.0
	var noon_day := clock.day
	var real := 0.0
	var set_at := -1.0
	var rise_at := -1.0
	var was_up := true
	while real < 2000.0 and not (clock.day > noon_day and clock.time_of_day >= 12.0):
		clock._process(1.0 / 30.0)
		real += 1.0 / 30.0
		var up := atmosphere_node.sun_direction().y > 0.0
		if was_up and not up and set_at < 0.0:
			set_at = real
		if up and not was_up and set_at > 0.0 and rise_at < 0.0:
			rise_at = real
		was_up = up
	var night_len := rise_at - set_at
	var day_len := real - night_len
	_check(set_at > 0.0 and absf(night_len - 600.0) < 3.0 and absf(day_len - 900.0) < 3.0,
			"clock node: %.0f s of daylight, %.0f s of night" % [day_len, night_len])
	clock.day = noon_day
	clock.time_of_day = 12.0

	# meteors fall only at night, at random; auroras come about one night in fifty
	var meteors: Meteors = world.get_node("Meteors")
	var before := meteors.launched
	meteors.update_sky(0.0)
	for i in 3000:   # 100 s of daylight
		meteors._process(1.0 / 30.0)
	var by_day := meteors.launched - before
	meteors.update_sky(1.0)
	for i in 18000:  # 10 minutes of night
		meteors._process(1.0 / 30.0)
		meteors.update_sky(1.0)
	var by_night := meteors.launched - before - by_day
	_check(by_day == 0 and by_night >= 10 and by_night <= 45, "meteors: %d in a 10-minute night, none by day" % by_night)
	var shower_nights := 0
	for n in 5000:
		if meteors.shower_for(n):
			shower_nights += 1
	meteors.set_forced_shower(true)
	meteors.update_sky(1.0, 77)
	var b1 := meteors.launched
	for i in 18000:
		meteors._process(1.0 / 30.0)
	var in_shower := meteors.launched - b1
	# every shower meteor travels directly away from the radiant
	var radial := true
	for m: Dictionary in meteors._active:
		var head: Vector3 = (m.start as Vector3).rotated(m.axis, 0.05)
		radial = radial and head.angle_to(meteors.radiant) > (m.start as Vector3).angle_to(meteors.radiant)
	meteors.set_forced_shower(false)
	_check(shower_nights > 60 and shower_nights < 140 and in_shower > 120 and radial,
			"meteor showers on %d of 5000 nights; %d meteors in a 10-minute shower night, all from one radiant" % [shower_nights, in_shower])
	var aurora: Aurora = world.get_node("Aurora")
	var nights_with := 0
	for n in 5000:
		if aurora.strength_for(n) > 0.0:
			nights_with += 1
	# curtains never cross: through many nights and times, each sits poleward of the last
	# by both fold amplitudes plus the minimum gap
	var crossed := 0
	var overhead := 0
	var kept_time := aurora.display_time
	for n in 200:
		for step in 12:
			aurora.display_time = step * 137.0
			var feet := aurora.curtain_feet(n)
			for k in range(1, feet.size()):
				if feet[k].x - feet[k - 1].x < feet[k].y + feet[k - 1].y + Aurora.MIN_GAP - 0.01:
					crossed += 1
			if step == 0 and absf(feet[0].x) < 300.0:
				overhead += 1
	aurora.display_time = kept_time
	_check(crossed == 0 and overhead > 10 and overhead < 120,
			"aurora curtains never cross; %d of 200 displays reach within 300 km of overhead" % overhead)
	# swirls fold curtains without tearing or crossing: warping is exactly undone by unwarping
	var swirl_set: Array[Vector4] = [Vector4(0, 300, 200, 3.0), Vector4(40, 280, 60, -2.5), Vector4(-300, 500, 120, 1.7)]
	var worst := 0.0
	var prng := RandomNumberGenerator.new()
	prng.seed = 4
	for i in 2000:
		var q := Vector2(prng.randf_range(-800, 800), prng.randf_range(-200, 900))
		worst = maxf(worst, Aurora.unwarp_point(Aurora.warp_point(q, swirl_set), swirl_set).distance_to(q))
	_check(worst < 1e-3, "aurora swirls are exact bijections (round trip error %.6f km)" % worst)
	aurora.set_forced(true)
	var forced_all := aurora.strength_for(3) > 0.0 and aurora.strength_for(4) > 0.0
	aurora.set_forced(false)
	_check(forced_all and aurora.strength_for(7) == aurora.strength_for(7), "debug key forces an aurora every night")
	_check(nights_with > 60 and nights_with < 140 and aurora.strength_for(7) == aurora.strength_for(7),
			"auroras on %d of 5000 nights (about 1 in %.0f), the same for a given night" % [nights_with, 5000.0 / maxf(nights_with, 1)])

	# diving by looking down
	player.respawn(Vector3(20, 0, 20))
	await _frames(30)
	var start_depth := player.head_depth()
	camera.pitch = 1.2   # look steeply down
	Input.action_press(&"move_forward")
	await _frames(150)
	Input.action_release(&"move_forward")
	var dived := player.head_depth() - start_depth
	camera.pitch = 0.0
	Input.action_press(&"tread")
	await _frames(240)
	Input.action_release(&"tread")
	_check(dived > 2.0 and player.head_depth() < 1.0,
			"looking down dives %.1f m, Space brings you back up" % dived)

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

	# land: walk on the baked ground
	var terrain: Terrain = world.get_node("Terrain")
	terrain.generate_now()
	var maps := Terrain.maps()
	var spot := Vector3.INF
	for i in maps.n * maps.n:
		var h := maps.height[i]
		if h > 5.0 and h < 200.0 and maps.water_level[i] <= WorldMaps.NO_WATER and maps.river_a[i * 4 + 3] == 0.0:
			var c := maps.to_world(i % maps.n, i / maps.n)
			if absf(maps.height_at(c.x + 20.0, c.y) - h) < 3.0 and absf(maps.height_at(c.x, c.y + 20.0) - h) < 3.0:
				spot = Vector3(c.x, h, c.y)
				break
	_check(spot != Vector3.INF, "found gentle dry land to stand on")
	if player.boat:
		player._leave_boat()
	player.respawn(spot + Vector3.UP * 3.0)
	player.global_position = spot + Vector3.UP * 3.0
	await _frames(120)
	var ground := Terrain.height_at(player.global_position.x, player.global_position.z)
	_check(player.state == &"WALKING" and absf(player.global_position.y - Player.CHEST - ground) < 0.6
			and Water.body_at(spot.x, spot.z) == null,
			"player stands on land (%s, feet %.2f m above the ground)" % [player.state, player.global_position.y - Player.CHEST - ground])

	# procedural legs: feet planted on the ground, stepping while walking
	player.model.visible = true
	var legs: ProceduralLegs = null
	for ch in player.get_children():
		if ch is ProceduralLegs:
			legs = ch
	await _frames(10)
	var planted := true
	for f in legs._feet:
		planted = planted and absf(f.y - Terrain.height_at(f.x, f.z)) < 0.15
	Input.action_press(&"move_forward")
	var start_feet := legs._feet.duplicate()
	await _frames(60)
	Input.action_release(&"move_forward")
	var stepped: bool = legs._feet[0].distance_to(start_feet[0]) > 0.3 and legs._feet[1].distance_to(start_feet[1]) > 0.3
	await _frames(30)
	for f in legs._feet:
		planted = planted and absf(f.y - Terrain.height_at(f.x, f.z)) < 0.15
	_check(legs != null and planted and stepped, "procedural legs plant both feet on the ground and step while walking")

	# Minecraft-style jump, and double-tap Space flight
	var y0 := player.global_position.y
	Input.action_press(&"tread")
	var peak := y0
	for _f in 20:
		await physics_frame
		peak = maxf(peak, player.global_position.y)
	Input.action_release(&"tread")
	await _frames(60)
	_check(peak - y0 > 0.8 and peak - y0 < 2.5 and player.state == &"WALKING",
			"holding Space jumps about a metre and lands (%.2f m)" % (peak - y0))
	for _tap in 2:
		var ev := InputEventAction.new()
		ev.action = &"tread"
		ev.pressed = true
		Input.parse_input_event(ev)
		await process_frame
		var up := InputEventAction.new()
		up.action = &"tread"
		up.pressed = false
		Input.parse_input_event(up)
		await process_frame
	var fly_y := player.global_position.y
	Input.action_press(&"tread")
	await _frames(60)
	Input.action_release(&"tread")
	_check(player.flying and player.state == &"FLYING" and player.global_position.y - fly_y > 20.0,
			"double-tapping Space flies, fast (rose %.0f m in 1 s)" % (player.global_position.y - fly_y))
	player.flying = false
	player.respawn(spot + Vector3.UP * 3.0)
	await _frames(30)

	# lakes and rivers are water bodies
	var lake_ok := true
	var lakes_seen := 0
	for i in maps.n * maps.n:
		if maps.water_kind[i] == WorldMaps.WaterKind.LAKE and maps.height[i] < maps.water_level[i] - 2.0:
			var c := maps.to_world(i % maps.n, i / maps.n)
			var lb := Water.body_at(c.x, c.y)
			lakes_seen += 1
			lake_ok = lake_ok and lb is LakeBody and absf(lb.surface_height(c.x, c.y) - maps.water_level[i]) < 0.01
			if lakes_seen > 20:
				break
	_check(lakes_seen == 0 or lake_ok, "lakes are water bodies at their level (%d cells checked)" % lakes_seen)
	var river_ok := false
	for i in maps.n * maps.n:
		var r := maps.river_at(maps.to_world(i % maps.n, i / maps.n).x, maps.to_world(i % maps.n, i / maps.n).y)
		if r.is_empty() or not r.wet:
			continue
		var c := maps.to_world(i % maps.n, i / maps.n) + Vector2(maps.river_a[i * 4], maps.river_a[i * 4 + 1])
		var rb := Water.body_at(c.x, c.y)
		if rb is RiverBody:
			var f := rb.flow_at(c.x, c.y)
			river_ok = f.length() > 0.2 and Vector2(f.x, f.z).dot(r.flow_dir) > 0.0
			break
	_check(river_ok, "rivers are water bodies whose current runs downstream")

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
