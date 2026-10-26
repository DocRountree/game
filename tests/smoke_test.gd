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
	var world: Node3D = load("res://src/world/open_ocean/open_ocean.tscn").instantiate()
	root.add_child(world)
	var ocean: Ocean = world.get_node("Ocean")
	var boat: Boat = world.get_node("Boat")
	var player: Player = world.get_node("Player")

	_check(_shader_compiles(), "ripple compute shader compiles to SPIR-V")
	_check(_lookup_consistent(ocean), "height_at() inverts the Gerstner displacement")
	await _frames(2)   # let the scene enter the tree and run _ready()
	var atmosphere: Atmosphere = world.get_node("Atmosphere")
	var sun: DirectionalLight3D = world.get_node("Sun")
	var start_time := atmosphere.time_of_day
	atmosphere.time_of_day = 12.0
	_check(absf(rad_to_deg(asin(atmosphere.sun_direction().y)) - 31.6) < 0.5,
			"winter solstice noon sun at 31.6 deg for 35N")
	atmosphere._update_sun()
	var noon := sun.light_color
	atmosphere.time_of_day = 16.6
	atmosphere._update_sun()
	var dusk := sun.light_color
	_check(noon.b > 0.6 and dusk.r > dusk.b * 2.0 and sun.light_energy > 0.0,
			"sunlight is white at noon and reddens at sunset")
	atmosphere.time_of_day = 0.0
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
	atmosphere.time_of_day = 22.0
	sky = atmosphere.equatorial_to_world()
	aldebaran = sky * Starfield._unit(deg_to_rad(68.98), deg_to_rad(16.51))
	var rising := sky * Starfield._unit(deg_to_rad(88.79), deg_to_rad(7.41))
	_check(aldebaran.x > 0.0 and rising.x > aldebaran.x, "22:00: Taurus and Orion still east of the meridian")
	atmosphere.time_of_day = 16.6
	_check(atmosphere.sun_direction().x < 0.0 and atmosphere.sun_direction().z > 0.0, "winter sun sets in the southwest")
	var planets := Planets.positions(Planets.julian_date(2020, 356, 18.0))
	_check((planets[3][1] as Vector3).angle_to(planets[4][1]) < deg_to_rad(0.5),
			"planets: Jupiter-Saturn great conjunction on 2020-12-21")
	var catalog: StarCatalog = world.get_node("Starfield").catalog
	_check(catalog.star_count() > 8000 and catalog.deep_sky_count() == 110, "star catalogue and all 110 Messier objects load")
	atmosphere.time_of_day = start_time

	await _frames(300)
	var boat_draft := boat.buoyancy.submerged * boat.buoyancy.max_depth   # mean probe depth
	_check(boat_draft > 0.05 and boat_draft < 0.5, "boat floats (draft %.2f m)" % boat_draft)
	var crate: RigidBody3D = world.get_node("Crates").get_child(0)
	var crate_top := crate.global_position.y + 0.5 - ocean.height_at(crate.global_position.x, crate.global_position.z)
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
	_check(boat.speed() > 6.0, "boat drives forward (%.1f m/s)" % boat.speed())

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


func _shader_compiles() -> bool:
	var file: RDShaderFile = load("res://src/systems/ocean/ripple_sim.glsl")
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		print(spirv.compile_error_compute)
	return spirv.compile_error_compute == "" and spirv.bytecode_compute.size() > 0


func _lookup_consistent(ocean: Ocean) -> bool:
	# displace a few rest points forward, then ask height_at() for the height above where they landed
	for p: Vector2 in [Vector2(3, 7), Vector2(-20, 11), Vector2(42, -5)]:
		var disp := Vector3.ZERO
		for i in ocean._n:
			var th := ocean._k[i] * (ocean._dx[i] * p.x + ocean._dz[i] * p.y) - ocean._omega[i] * ocean.time + ocean._phase[i]
			disp += Vector3(ocean.steepness * ocean._amp[i] * ocean._dx[i] * cos(th), ocean._amp[i] * sin(th),
					ocean.steepness * ocean._amp[i] * ocean._dz[i] * cos(th))
		if absf(ocean.height_at(p.x + disp.x, p.y + disp.z) - disp.y) > 0.02:
			return false
	return true
