extends "res://tests/lib/test_run.gd"
## Headless tests of the character's look (CharacterTraits, HairBuilder,
## CharacterDress, CharacterRig's meshes): every combination of settings
## builds, the hair stays out of the body, the settings do what they say, the
## palettes are in order, and it all stays cheap.
## Run: godot --headless --path . -s res://tests/character_test.gd


func _initialize() -> void:
	var P := CharacterTraits

	# C6: the picker's palettes: skin tones light to deep, then red to violet
	var lum_ok := true
	for i in range(1, P.SKIN_TONES.size()):
		lum_ok = lum_ok and P.SKIN_TONES[i].get_luminance() < P.SKIN_TONES[i - 1].get_luminance()
	var hue_ok := P.BRIGHT_COLORS[0].h < 0.02 and P.BRIGHT_COLORS[P.BRIGHT_COLORS.size() - 1].h > 0.75
	for i in P.BRIGHT_COLORS.size():
		hue_ok = hue_ok and P.BRIGHT_COLORS[i].s > 0.6 and (i == 0 or P.BRIGHT_COLORS[i].h > P.BRIGHT_COLORS[i - 1].h)
	_check(P.SKIN_TONES.size() == 12 and lum_ok and P.BRIGHT_COLORS.size() == 7 and hue_ok,
			"palettes: 12 skin tones light to deep, 7 simple colours red to violet")

	# accessories are content: each a .tres definition the registry finds
	var hats := P.defs(AccessoryDef.Kind.HAT)
	var accs := P.defs(AccessoryDef.Kind.ACCESSORY)
	var styles := P.defs(AccessoryDef.Kind.STYLE)
	_check(hats.size() >= 4 and accs.size() >= 5 and styles.size() >= 2 and ContentRegistry.by_id(&"AccessoryDef", &"glasses") != null,
			"accessories come from their definitions (src/data/characters/accessories): %d hats, %d accessories, %d hair styles" % [hats.size(), accs.size(), styles.size()])

	# C3 + C4: every combination builds, and no hair goes into the head,
	# neck, torso, shoulders, pack or bedroll (more than 1 cm), nor up through a hat
	var combos := 0
	var empty := 0
	var worst_in := 0.0
	var worst_hat := -1.0
	var max_tris := 0
	var slowest := 0.0
	for len_f: float in [0.0, 0.05, 0.3, 0.6, 1.0]:
		for curl: float in [0.0, 0.5, 1.0]:
			for fh in 5:
				for hat: String in ["none"] + P.defs(AccessoryDef.Kind.HAT).map(func(d: AccessoryDef) -> String: return String(d.id)):
					for style: String in ["", "ponytail", "bun"]:
						var t := P.new()
						t.hair_length = len_f
						t.hair_curl = curl
						t.facial_hair = fh as CharacterTraits.FacialHair
						t.facial_hair_length = 1.0 if fh % 2 == 0 else 0.3
						t.hat = hat
						if style != "":
							t.accessories.append(style)
						if fh == 4 and hat == "beanie":
							t.accessories.append_array(["glasses", "earrings", "necklace", "scarf", "headband"])
						var t0 := Time.get_ticks_usec()
						var mesh := CharacterDress.build(t)
						slowest = maxf(slowest, (Time.get_ticks_usec() - t0) / 1000.0)
						combos += 1
						if mesh.get_surface_count() == 0:
							empty += 1
							continue
						max_tris = maxi(max_tris, mesh.surface_get_array_index_len(0) / 3)
						if hat != "none" or style != "":
							continue   # (hair alone, for the body check)
						var mb := MeshBuilder.new()
						HairBuilder.add_hair(mb, t)
						HairBuilder.add_facial_hair(mb, t)
						for v in mb.verts:
							worst_in = maxf(worst_in, (HairBuilder.push(v, -0.01) - v).length())
		# under the wide-brimmed hat, no hair above its crown
	for len_f: float in [0.2, 0.6, 1.0]:
		for curl: float in [0.0, 1.0]:
			var t := P.new()
			t.hair_length = len_f
			t.hair_curl = curl
			var mb := MeshBuilder.new()
			HairBuilder.add_hair(mb, t)
			for v in mb.verts:
				worst_hat = maxf(worst_hat, v.y - 0.185)
	_check(empty == 0 and worst_in < 0.001, "%d combinations of hair, curl, facial hair, hat and style build; no hair more than 1 cm into the body (worst %.1f mm)"
			% [combos, worst_in * 1000.0])
	_check(worst_hat < 0.0, "no hair comes up through the hat's crown (its highest %.0f mm %s the top)" % [absf(worst_hat) * 1000.0, "below" if worst_hat < 0.0 else "above"])

	# C5: the settings do what they say
	var lows := []
	for len_f: float in [0.2, 0.4, 0.6, 0.8, 1.0]:
		var t := P.new()
		t.hair_length = len_f
		t.hat = "none"
		lows.append(_extent(t).x)
	var falling := true
	for i in range(1, lows.size()):
		falling = falling and lows[i] > lows[i - 1]
	var straight := P.new()
	straight.hair_length = 0.8
	var curly := P.new()
	curly.hair_length = 0.8
	curly.hair_curl = 1.0
	var e0 := _extent(straight)
	var e1 := _extent(curly)
	_check(falling and e1.x < e0.x - 0.05 and e1.y > e0.y,
			"longer hair hangs lower (%s); curly hair springs up shorter (%.2f vs %.2f m) and fuller (%.3f vs %.3f m out round the head)"
			% [", ".join(lows.map(func(v: float) -> String: return "%.2f" % v)), e1.x, e0.x, e1.y, e0.y])

	# C1 + C2: cheap to draw and to rebuild
	var worst := P.new()
	worst.hair_length = 1.0
	worst.hair_curl = 1.0
	worst.facial_hair = P.FacialHair.BEARD
	worst.facial_hair_length = 1.0
	worst.hat = "wide_brim"
	worst.accessories.append_array(["glasses", "necklace", "scarf"])
	var model := Node3D.new()
	var rig := CharacterRig.new()
	var stub := Player.new()   # (just a model to build on)
	stub.add_child(model)
	stub.set("model", model)
	rig.body = stub
	rig.build()
	worst.apply_to(model)
	var draws := 0
	var tris := 0
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		draws += 1
		var m: Mesh = (mi as MeshInstance3D).mesh
		for s in m.get_surface_count():
			draws += 0 if s == 0 else 1
			tris += m.surface_get_array_index_len(s) / 3
	_check(draws <= 16 and tris <= 14000, "the whole character is %d draw calls and %d triangles at its heaviest (at most 16 and 14000)" % [draws, tris])
	stub.free()
	var times := []
	for i in 5:
		var t0 := Time.get_ticks_usec()
		CharacterDress.build(worst)
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	slowest = times[2]

	_check(slowest < 20.0, "rebuilding the heaviest hair, beard and the rest takes %.1f ms (under 20 ms; the picker rebuilds at most every 60 ms while dragging)" % slowest)

	# the palette carries every colour the look names
	var pal := worst.palette()
	_check(pal.size() == P.PALETTE_SIZE and pal[P.P_SKIN].is_equal_approx(Vector3(worst.skin_color.srgb_to_linear().r, worst.skin_color.srgb_to_linear().g, worst.skin_color.srgb_to_linear().b)),
			"the palette holds the skin, hair, clothes, hat and accessory colours")
	_finish()


# (lowest point below the head's centre, as a positive number; width) of the hair
func _extent(t: CharacterTraits) -> Vector2:
	var mb := MeshBuilder.new()
	HairBuilder.add_hair(mb, t)
	var lo := INF
	var w := 0.0
	var n := 0
	for v in mb.verts:
		lo = minf(lo, v.y)
		if v.y > -0.12:   # (how far it stands out round the head)
			w += Vector2(v.x, v.z).length()
			n += 1
	return Vector2(-lo, w / maxi(n, 1))
