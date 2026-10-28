extends SceneTree
## Headless smoke test: loads the main scene, simulates, and checks the core
## water gameplay. Exit code 0 = pass.
##
##   godot --headless --path . -s res://tests/smoke_test.gd
##
## Headless has no GPU, so this covers the no-ripples fallback path; the
## ripple simulation itself needs a real renderer.

var _failures := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	Terrain.bake_resolution = 512   # a coarse world: quick to bake
	var world: Node3D = load("res://src/world/open_ocean/open_ocean.tscn").instantiate()
	root.add_child(world)
	var ocean: Ocean = world.get_node("Ocean")
	var boat: Boat = world.get_node("Boat")
	var player: Player = world.get_node("Player")

	_check(_shader_compiles("res://src/systems/water/ocean/ripple_sim.glsl"), "ripple compute shader compiles to SPIR-V")
	_check(_shader_compiles("res://src/systems/water/ocean/ocean_fft.glsl"), "FFT ocean compute shader compiles to SPIR-V")
	_check(_lookup_consistent(ocean), "surface_height() inverts the Gerstner displacement")
	await _frames(2)   # let the scene enter the tree and run _ready()
	var atmosphere: Atmosphere = world.get_node("Atmosphere")
	var clock: GameClock = world.get_node("Clock")
	var sun: DirectionalLight3D = world.get_node("Sun")
	_check(GameClock.current() == clock and root.get_node("Game").world == world
			and root.get_node("Game").player == player, "level registers its world, clock and player with Game")
	var start_time := clock.time_of_day
	_check(absf(start_time - 12.0) < 0.1, "the day starts at noon")
	clock.time_of_day = 12.0
	_check(absf(rad_to_deg(asin(atmosphere.sun_direction().y)) - 31.6) < 0.5,
			"winter solstice noon sun at 31.6 deg for 35N")
	atmosphere._update_sun()
	var noon := sun.light_color
	clock.time_of_day = 16.6
	atmosphere._update_sun()
	var dusk := sun.light_color
	_check(noon.b > 0.6 and dusk.r > dusk.b * 2.0 and sun.light_energy > 0.0,
			"sunlight is white at noon and reddens at sunset")
	clock.time_of_day = 0.0
	atmosphere._update_sun()
	_check(sun.light_energy == 0.0, "no sunlight at night")
	var sky := atmosphere.equatorial_to_world()
	var betelgeuse := sky * Starfield._unit(deg_to_rad(88.79), deg_to_rad(7.41))
	var polaris := sky * Starfield._unit(deg_to_rad(37.95), deg_to_rad(89.26))
	# facing south (+Z) with up +Y, east (+X) must be on the left, as in the real sky
	var aldebaran := sky * Starfield._unit(deg_to_rad(68.98), deg_to_rad(16.51))
	_check(betelgeuse.y > 0.85 and betelgeuse.z > 0.0 and polaris.z < 0.0
			and absf(rad_to_deg(asin(polaris.y)) - 35.0) < 1.0,
			"Dec 21 midnight: Orion high in the south, Polaris 35 deg up in the north")
	clock.time_of_day = 22.0
	sky = atmosphere.equatorial_to_world()
	aldebaran = sky * Starfield._unit(deg_to_rad(68.98), deg_to_rad(16.51))
	var rising := sky * Starfield._unit(deg_to_rad(88.79), deg_to_rad(7.41))
	_check(aldebaran.x > 0.0 and rising.x > aldebaran.x, "22:00: Taurus and Orion still east of the meridian")
	clock.time_of_day = 16.6
	_check(atmosphere.sun_direction().x < 0.0 and atmosphere.sun_direction().z > 0.0, "winter sun sets in the southwest")
	var planets := Planets.positions(Planets.julian_date(2020, 356, 18.0))
	_check((planets[3][1] as Vector3).angle_to(planets[4][1]) < deg_to_rad(0.5),
			"planets: Jupiter-Saturn great conjunction on 2020-12-21")
	# planets wander: outer ones about as fast as the moon, Venus stays near the fixed sun
	var cfg := WorldConfig.current()
	var sun_eq := Planets.sun_direction(Astronomy.julian_date(cfg, 0.0))
	var max_venus := 0.0
	for d in range(0, 400, 4):
		max_venus = maxf(max_venus, rad_to_deg((Astronomy.planet_positions(cfg, d, 0.0)[1][1] as Vector3).angle_to(sun_eq)))
	var rates := []
	for i in [2, 3, 4, 5]:   # Mars .. Uranus: degrees moved in one day
		var a0: Vector3 = Astronomy.planet_positions(cfg, 10, 0.0)[i][1]
		var a1: Vector3 = Astronomy.planet_positions(cfg, 11, 0.0)[i][1]
		rates.append(rad_to_deg(a0.angle_to(a1)))
	_check(max_venus < 48.0 and rates.min() > 8.0 and rates.max() < 20.0,
			"outer planets cross the stars at moon pace (%.0f-%.0f deg/day), Venus within %.0f deg of the sun"
			% [rates.min(), rates.max(), max_venus])
	var catalog: StarCatalog = world.get_node("Starfield").catalog
	_check(catalog.star_count() > 8000 and catalog.deep_sky_count() == 110, "star catalogue and all 110 Messier objects load")
	# clock: 15 real minutes of daylight, 5 of night
	var day_s := 0.0
	var night_s := 0.0
	var t := 12.0
	var wrapped := false
	while not (wrapped and t >= 12.0):
		var up := atmosphere.sun_direction(t).y > 0.0
		t += clock.rate(t) / 30.0
		if t >= 24.0:
			t -= 24.0
			wrapped = true
		if up: day_s += 1.0 / 30.0
		else: night_s += 1.0 / 30.0
	_check(absf(day_s - 900.0) < 3.0 and absf(night_s - 600.0) < 3.0,
			"days last 15 real minutes, nights 10 (%.0f s / %.0f s)" % [day_s, night_s])
	# moon: a new phase every day (8-day cycle), and it is up at noon on some days only
	var phases := []
	var names := []
	var up_at_noon := 0
	for d in 16:
		clock.day = d
		clock.time_of_day = 12.0
		phases.append((1.0 - atmosphere.moon_direction().dot(atmosphere.sun_direction())) * 0.5)
		names.append(atmosphere.moon_phase_text())
		if atmosphere.moon_direction().y > 0.0:
			up_at_noon += 1
	var daily := true
	for d in range(1, 16):
		daily = daily and names[d] != names[d - 1]
	var week: Array = names.slice(0, 8)
	var distinct := {}
	for n in week:
		distinct[n] = true
	_check(daily and distinct.size() == 8 and names[8] == names[0] and phases.max() > 0.9 and phases.min() < 0.1
			and up_at_noon > 3 and up_at_noon < 13,
			"moon phase changes every day through all 8 phases (%s, ...) and is up by day on %d of 16 days" % [names[0], up_at_noon])
	clock.day = 0
	# starts in first person: camera at the head, own model hidden; F5 goes to third person and back
	# (headless runs don't route synthetic input, so the action goes straight to the handler)
	var f5_bound := InputMap.action_get_events(&"toggle_view").any(
			func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_F5)
	var camera: PlayerCamera = world.get_node("Camera")
	for i in 3:   # the camera moves in _process; physics frames can come in bursts before it runs
		await process_frame
	var head: Node3D = player.get_node("Model/Head")
	_check(f5_bound and camera.first_person and not player.model.visible
			and camera.global_position.distance_to(head.global_position) < 0.2, "the game starts in first person at the head")
	var press := InputEventAction.new()
	press.action = &"toggle_view"
	press.pressed = true
	world._unhandled_input(press)
	for i in 3:
		await process_frame
	_check(not camera.first_person and player.model.visible, "F5 switches to third person")
	world._unhandled_input(press)
	for i in 3:
		await process_frame
	_check(camera.first_person and not player.model.visible, "F5 again returns to first person")
	# looking around turns the swimmer, and the view stays put when the mouse stops
	camera.yaw = 1.0
	for i in 60:
		await process_frame
	_check(absf(camera.yaw - 1.0) < 1e-4 and absf(angle_difference(player.model.rotation.y, 1.0)) < 0.05,
			"the view holds where it's left and the body faces it")
	camera.yaw = PI
	clock.time_of_day = start_time

	await _frames(300)
	var boat_draft := boat.buoyancy.submerged * boat.buoyancy.max_depth   # mean probe depth
	_check(boat_draft > 0.05 and boat_draft < 0.5, "boat floats (draft %.2f m)" % boat_draft)
	var crate: RigidBody3D = world.get_node("Crates").get_child(0)
	var crate_top := crate.global_position.y + 0.5 - ocean.surface_height(crate.global_position.x, crate.global_position.z)
	_check(crate_top > 0.0 and crate_top < 1.0, "crate floats (%.2f m above water)" % crate_top)

	await _frames(360)   # idle: should sink
	_check(player.state == &"SINKING" and player.head_depth() > 1.0,
			"idle player sinks (head %.1f m under)" % player.head_depth())

	Input.action_press(&"tread")
	await _frames(480)
	Input.action_release(&"tread")
	_check(player.head_depth() < 0.0, "treading brings the head back above water")

	player.respawn(boat.global_position + boat.global_basis.x * 3.0)
	await _frames(5)
	player._try_board()
	_check(player.boat == boat, "player can board the boat")
	Input.action_press(&"move_forward")
	await _frames(600)
	Input.action_release(&"move_forward")
	_check(boat.speed() > 6.0 and boat.global_basis.y.dot(Vector3.UP) > 0.8,
			"boat drives forward upright (%.1f m/s)" % boat.speed())
	var heading := boat.global_rotation.y
	var body := player.model.rotation.y
	camera.yaw += 1.2
	for i in 3:
		await process_frame
	var turned := angle_difference(heading, boat.global_rotation.y)
	_check(absf(turned) < 0.05 and absf(angle_difference(body, player.model.rotation.y) - 1.2 + turned) < 0.1,
			"looking around aboard turns the body, not the boat")

	# regression: re-enabling the player's collision used to launch the boat
	var before := boat.speed()
	player._leave_boat()
	await _frames(30)
	_check(boat.speed() <= before + 0.5, "jumping off doesn't kick the boat (%.1f -> %.1f m/s)" % [before, boat.speed()])

	print("\n%s: %d failure(s)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures else 0)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _check(ok: bool, what: String) -> void:
	print(("  ok    " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1


func _shader_compiles(path: String) -> bool:
	var file: RDShaderFile = load(path)
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		print(spirv.compile_error_compute)
	return spirv.compile_error_compute == "" and spirv.bytecode_compute.size() > 0


func _lookup_consistent(ocean: Ocean) -> bool:
	# displace a few rest points forward, then ask surface_height() for the height above where they landed
	for p: Vector2 in [Vector2(3, 7), Vector2(-20, 11), Vector2(42, -5)]:
		var disp := Vector3.ZERO
		for i in ocean._n:
			var th := ocean._k[i] * (ocean._dx[i] * p.x + ocean._dz[i] * p.y) - ocean._omega[i] * ocean.time + ocean._phase[i]
			disp += Vector3(ocean.steepness * ocean._amp[i] * ocean._dx[i] * cos(th), ocean._amp[i] * sin(th),
					ocean.steepness * ocean._amp[i] * ocean._dz[i] * cos(th))
		if absf(ocean.surface_height(p.x + disp.x, p.y + disp.z) - disp.y) > 0.02:
			return false
	return true
