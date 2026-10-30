extends "res://tests/lib/test_run.gd"
## Headless checks of the player in the debug world: flight, standing on the
## beach, the rivers as water bodies, climbing (onto the top, and on past a
## waterfall's ledges), the camera keeping out of the ground, and the
## character picker. Exit code 0 = pass.
##
##   godot --headless --path . -s res://tests/player_test.gd


func _initialize() -> void:
	_run()


func _run() -> void:
	var world := _load_world()
	await _frames(2)
	var player: Player = world.get_node("Player")
	var boat: Boat = world.get_node("Boat")
	var camera: PlayerCamera = world.get_node("Camera")
	# double-tapping Space flies (and the procedural legs come along)
	var legs_ok := false
	for ch in player.get_children():
		legs_ok = legs_ok or ch is CharacterRig
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
	_check(legs_ok and player.flying and player.state == &"FLY" and player.global_position.y - fly_y > 20.0,
			"double-tapping Space flies, fast (rose %.0f m in 1 s); the player has a procedural body" % (player.global_position.y - fly_y))
	player.flying = false

	# land: you start on the beach, standing on the generated ground
	var w := WorldData.get_world()
	var terrain: Terrain = world.get_node("World/Terrain")
	if player.boat:
		(player.mode as DriveMode).jump_off()
	var spot := Vector3(w.spawn.x, 0.0, w.spawn.y)
	terrain.prepare_at(spot)
	player.respawn(Vector3(spot.x, Terrain.height_at(spot.x, spot.z) + 1.4, spot.z))
	await _frames(90)
	var ground := Terrain.height_at(player.global_position.x, player.global_position.z)
	_check(player.pose == &"WALKING" and absf(player.global_position.y - Player.CHEST - ground) < 0.3
			and Water.body_at(spot.x, spot.z) == null,
			"player stands on the beach (%s, feet %.2f m above the ground)" % [player.state, player.global_position.y - Player.CHEST - ground])

	# rivers are water bodies whose current runs downstream
	var river_ok := false
	var trunk: RiverData = w.rivers[0]
	var pts: PackedVector3Array = trunk.points
	for k in range(pts.size() / 2, pts.size() - 2):
		if Terrain.height_at(pts[k].x, pts[k].z) > pts[k].y - 0.5 or Terrain.height_at(pts[k].x, pts[k].z) < 0.5:
			continue
		var rb := Water.body_at(pts[k].x, pts[k].z)
		if rb is RiverBody:
			var f := rb.flow_at(pts[k].x, pts[k].z)
			var down := Vector2(pts[k + 1].x - pts[k - 1].x, pts[k + 1].z - pts[k - 1].z)
			river_ok = f.length() > 0.2 and Vector2(f.x, f.z).dot(down) > 0.0 and absf(rb.surface_height(pts[k].x, pts[k].z) - pts[k].y) < 0.5
			break
	_check(river_ok, "rivers are water bodies at their level, whose current runs downstream")

	# E climbs ground too steep to walk on; WASD moves on the rock; E lets go
	var c: Array = w.landmasses[0].center
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var wall := Vector3.ZERO
	var uphill := Vector2.ZERO
	for k in 20000:
		var x := float(c[0]) + rng.randf_range(-3000.0, 3000.0)
		var z := float(c[1]) + rng.randf_range(-3000.0, 3000.0)
		var g := Vector2(Terrain.height_at(x + 2.0, z) - Terrain.height_at(x - 2.0, z),
				Terrain.height_at(x, z + 2.0) - Terrain.height_at(x, z - 2.0)) / 4.0
		if g.length() > 1.6 and g.length() < 3.0 and Terrain.height_at(x, z) > 20.0:
			wall = Vector3(x, Terrain.height_at(x, z), z)
			uphill = g.normalized()
			break
	var at := wall - Vector3(uphill.x, 0.0, uphill.y)
	terrain.prepare_at(at)
	player.respawn(Vector3(at.x, Terrain.height_at(at.x, at.z) + 1.0, at.z))
	camera.yaw = atan2(-uphill.x, -uphill.y)   # look at the rock (the body faces where the camera looks)
	camera.pitch = 0.0
	await _frames(10)
	var view_before := camera.first_person
	var e_key := InputEventAction.new()
	e_key.action = &"climb"
	e_key.pressed = true
	Input.parse_input_event(e_key)
	await _frames(5)
	var grabbed := player.climbing and player.climb_normal.y < Player.CLIMBABLE_Y
	var climb_y := player.global_position.y
	Input.action_press(&"move_forward")
	await _frames(60)
	Input.action_release(&"move_forward")
	var rose := player.global_position.y - climb_y
	var held := player.climbing and player.state == &"CLIMB"
	var third := not camera.first_person and player.model.visible
	Input.parse_input_event(e_key)
	await _frames(5)
	var let_go_ok := not player.climbing
	var view_back := camera.first_person == view_before
	await _frames(90)
	var after := player.global_position.y - Player.CHEST - Terrain.height_at(player.global_position.x, player.global_position.z)
	_check(wall != Vector3.ZERO and grabbed and held and rose > 1.0 and let_go_ok and after > -0.3,
			"E grabs a slope too steep to walk (normal.y %.2f), W climbs it (%.1f m in 1 s), E lets go (and you land, %.2f m above the ground)"
			% [player.climb_normal.y, rose, after])

	# climbing on up to the top pulls you over it, standing on the ground
	player.respawn(Vector3(at.x, Terrain.height_at(at.x, at.z) + 1.0, at.z))
	await _frames(10)
	Input.parse_input_event(e_key)
	await _frames(5)
	var regrabbed := player.climbing
	Input.action_press(&"move_forward")
	var climb_frames := 0
	while player.climbing and climb_frames < 1800:
		await physics_frame
		climb_frames += 1
	Input.action_release(&"move_forward")
	await _frames(90)
	var stand := player.global_position.y - Player.CHEST - Terrain.height_at(player.global_position.x, player.global_position.z)
	_check(third and view_back, "climbing switches to third person, and back to the view you had once you let go")
	_check(regrabbed and not player.climbing and player.pose == &"WALKING" and absf(stand) < 0.4,
			"climbing to the top pulls you over it, standing on the ground (%s after %.1f s, feet %.2f m above it)"
			% [player.state, climb_frames / 60.0, stand])

	# up a waterfall's rock you climb on past its ledges (too small to stand
	# on), not pulled up onto every one, until you're up near its lip
	var tallest: Array = w.river_network.falls_by_height()[0]
	var tall := {"r": tallest[0], "k0": tallest[1].first, "k1": tallest[1].last, "h": tallest[1].drop}
	var fp: PackedVector3Array = tall.r.points
	var km: int = (tall.k0 + tall.k1) / 2
	var fdir := fp[km + 1] - fp[km - 1]
	fdir.y = 0.0
	fdir = fdir.normalized()
	var fside := Vector3(-fdir.z, 0.0, fdir.x) * float(tall.r.half_width[km]) * 0.4   # (in among its streams and ledges)
	var out_there := fp[km] + fside + fdir * 10.0
	terrain.prepare_at(out_there)
	await _frames(3)
	var to_rock := PhysicsRayQueryParameters3D.create(out_there, out_there - fdir * 20.0)
	to_rock.exclude = [player.get_rid()]
	var rock_hit := player.get_world_3d().direct_space_state.intersect_ray(to_rock)
	var on_face: Vector3 = (rock_hit.position + rock_hit.normal * 0.6) if rock_hit else out_there
	player.respawn(on_face)
	camera.yaw = atan2(fdir.x, fdir.z)
	camera.pitch = 0.0
	for i in 3:   # (the body turns to the camera in _process: physics frames can come in bursts before it runs)
		await process_frame
	Input.parse_input_event(e_key)
	await _frames(3)
	var face_grab := player.climbing
	var top_y: float = fp[tall.k0].y
	var highest := player.global_position.y
	Input.action_press(&"move_forward")
	climb_frames = 0
	while player.climbing and climb_frames < 2400:
		await physics_frame
		climb_frames += 1
		highest = maxf(highest, player.global_position.y)
	Input.action_release(&"move_forward")
	if player.climbing:
		Input.parse_input_event(e_key)
		await _frames(5)
	_check(face_grab and highest > top_y - 3.0,
			"up a waterfall's rock (%.0f m) you climb on past its ledges to near its lip (from %.1f m below it to %.1f m below it)"
			% [tall.h, top_y - on_face.y, top_y - highest])

	# the third-person camera comes in in front of the ground rather than
	# looking through it (swung round to the uphill side of the slope)
	player.respawn(Vector3(at.x, Terrain.height_at(at.x, at.z) + 1.0, at.z))
	camera.first_person = false
	camera.yaw = atan2(uphill.x, uphill.y)
	camera.pitch = 0.1
	await _frames(30)
	var eye := camera.global_position
	var focus := player.global_position + camera.target_offset
	var sight := PhysicsRayQueryParameters3D.create(focus, eye, 1)
	sight.exclude = [player.get_rid()]
	var through := not player.get_world_3d().direct_space_state.intersect_ray(sight).is_empty()
	var above := eye.y - Terrain.height_at(eye.x, eye.z)
	_check(not through and above > 0.3,
			"the third-person camera never looks through the ground (%.2f m above it, clear view: %s)" % [above, not through])

	# C opens the character picker (debug world): the player stands still,
	# a camera faces them; sliders reshape the hair, swatches recolour, and
	# Done saves the look (here to a scratch file) and puts everything back
	var c_bound := InputMap.action_get_events(&"character_picker").any(
			func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_C)
	var picker: CharacterPicker = world.debug.picker
	picker.save_path = "user://test_character.tres"
	var cam_before := player.get_viewport().get_camera_3d()
	var press_c := InputEventAction.new()
	press_c.action = &"character_picker"
	press_c.pressed = true
	world.debug._unhandled_input(press_c)
	await _frames(3)
	var opened := picker.is_open and player.input_locked and player.get_viewport().get_camera_3d() != cam_before \
			and player.model.visible and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	# (once it has settled from wherever the last test left it)
	await _frames(60)
	var stood := player.global_position
	Input.action_press(&"move_forward")
	await _frames(60)
	Input.action_release(&"move_forward")
	var moved := player.global_position - stood
	var drift := Vector2(moved.x, moved.z).length()
	var dress := player.model.get_meta(&"dress") as MeshInstance3D
	var tris_before: int = dress.mesh.surface_get_array_index_len(0)
	picker.hair_length_slider.value = 1.0
	await _frames(10)
	var reshaped: bool = dress.mesh.surface_get_array_index_len(0) != tris_before and player.traits.hair_length == 1.0
	(picker._swatch_groups["skin"][12][0] as Button).pressed.emit()   # (the first simple colour: red)
	var mat := player.model.get_meta(&"character_material") as ShaderMaterial
	var red: Vector3 = mat.get_shader_parameter("palette")[CharacterTraits.P_SKIN]
	var recoloured := red.x > 0.5 and red.y < 0.1
	world.debug._unhandled_input(press_c)
	await _frames(3)
	var saved_look := load("user://test_character.tres") as CharacterTraits
	var closed := not picker.is_open and not player.input_locked and player.get_viewport().get_camera_3d() == cam_before
	_check(c_bound and opened and drift < 0.05, "C opens the character picker: the player stands still (moved %.2f m with W held) and a camera faces them" % drift)
	_check(reshaped and recoloured, "the picker's sliders reshape the hair and its swatches recolour (skin %s)" % red)
	_check(closed and saved_look != null and saved_look.hair_length == 1.0 and saved_look.skin_color.is_equal_approx(CharacterTraits.BRIGHT_COLORS[0]),
			"C closes it, saving the look (it loads back the same), with the view as it was")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_character.tres"))

	_finish()
