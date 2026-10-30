extends "res://tests/lib/test_run.gd"
## Headless checks of the river ribbon's stages on a made-up river over
## made-up ground (no generated world needed): a straight river down a gentle
## slope with one 12 m waterfall, its ground (a TerrainSource) a channel cut
## along it. Each stage on its own: the centreline (RibbonCentreline), the
## fall's span (RibbonFallSpans), the cross-sections (RibbonSections), the
## fall's rock and landings (FallGeometry), and the whole mesh (RiverRibbons).
##
##   godot --headless --path . -s res://tests/river_test.gd


## Ground: a slope falling 1 m in 100 along +z, dropping 12 m over 4 m at
## z = 200 (the fall), with a 1.5 m deep channel 20 m wide along x = 0.
class TestGround extends TerrainSource:
	func height_at(x: float, z: float) -> float:
		var base := -z * 0.01 - 12.0 * smoothstep(200.0, 204.0, z)
		var channel := 1.5 * (1.0 - smoothstep(9.0, 12.0, absf(x)))
		return base + 3.0 - channel - 0.5


func _initialize() -> void:
	var ground := TestGround.new()
	# the river: a point every 5 m, finely down the fall's face
	var pts := PackedVector3Array()
	var ris := PackedFloat32Array()
	var fall := Vector2i(-1, -1)
	var z := 0.0
	while z <= 400.0:
		if z >= 200.0 and z <= 204.0:
			var level := -2.0 - 12.0 * smoothstep(200.0, 204.0, z) + 2.5
			if fall.x < 0:
				fall.x = pts.size()
			pts.append(Vector3(0.0, level, z))
			ris.append(smoothstep(200.0, 204.0, z))
			fall.y = pts.size() - 1
			z += 0.1
			continue
		pts.append(Vector3(0.0, ground.height_at(0.0, z) + 1.4, z))
		ris.append(-1.0)
		z += 5.0
	var hw := PackedFloat32Array()
	var dep := PackedFloat32Array()
	for k in pts.size():
		hw.append(10.0)
		dep.append(1.0 if ris[k] < 0.0 else 0.4)
	for k in range(1, pts.size()):   # (always downhill)
		pts[k].y = minf(pts[k].y, pts[k - 1].y)
	var falls: Array[Vector2i] = [fall]
	var river := RiverData.new(pts, hw, dep, ris, falls, -1)
	_check(river.falls.size() == 1 and absf(river.falls[0].drop - 12.0) < 1.0 and river.fall_at(fall.x + 1) == river.falls[0]
			and river.speed.size() == pts.size(), "RiverData: its fall (%.1f m) and current" % river.falls[0].drop)

	# stage 1: the centreline
	var c := RibbonCentreline.resample(river)
	var widest_gap := 0.0
	for k in range(1, c.count):
		widest_gap = maxf(widest_gap, c.run[k] - c.run[k - 1])
	var fine := PackedInt32Array()
	fine.resize(c.count)
	c.frames(fine)
	var unit := true
	for t in c.tans:
		unit = unit and absf(t.length() - 1.0) < 1e-3 and t.y > 0.99
	_check(widest_gap <= RibbonCentreline.STEP + 1e-3 and unit,
			"centreline: samples at most %.1f m apart (widest %.2f), across directions unit and square to it" % [RibbonCentreline.STEP, widest_gap])

	# stage 2: the fall's span
	var geo := FallGeometry.new()
	var spans := RibbonFallSpans.find(c, geo)
	var above := 0
	for k in c.count:
		above += 1 if spans.lip_of[k] >= 0 else 0
	_check(spans.runs.size() == 1 and geo.faces.size() == 1 and absf(geo.faces[0].height - 12.0) < 1.0 and above > 3,
			"fall spans: one face (%.1f m), with %d samples just above its lip" % [geo.faces[0].height, above])

	# stage 3: the cross-sections
	fine = RibbonSections.resolution(c, spans, geo)
	c.frames(fine)
	c.compute_spread(river.mouth(), PackedVector3Array(), PackedFloat32Array(), 0.0)
	var sec := RibbonSections.build(c, spans, geo, fine, ground)
	sec.settle(ground)
	var face_rows := 0
	var rock_rows := 0
	var water_over_rock := 0
	var points := 0
	for ri in sec.rows.size():
		if spans.sheet[sec.row_k[ri]] >= 0.0:
			face_rows += 1
		if not sec.row_rock[ri].is_empty():
			rock_rows += 1
			if spans.sheet[sec.row_k[ri]] >= 0.0:
				for q in sec.rows[ri].size():
					if absf(sec.row_x[ri][q]) < 0.8:
						points += 1
						water_over_rock += 1 if sec.rows[ri][q].y >= ground.surface_at(sec.rows[ri][q].x, sec.rows[ri][q].z) - 0.01 else 0
	_check(face_rows > 10 and rock_rows >= face_rows and points > 100 and water_over_rock > points * 0.99,
			"sections: %d down the face, each with its rock; the water over the ground at %d of %d points" % [face_rows, water_over_rock, points])

	# the whole mesh, and the fall's rock and landings
	var geo2 := FallGeometry.new()
	var rivers: Array[RiverData] = [river]
	var mesh := RiverRibbons.build(rivers, ground, geo2)
	var arr := mesh.surface_get_arrays(0)
	_check(arr[Mesh.ARRAY_VERTEX].size() > 1000 and arr[Mesh.ARRAY_CUSTOM0].size() == arr[Mesh.ARRAY_VERTEX].size() * 4
			and geo2.rock_mesh().get_surface_count() == 1 and geo2.feet.size() >= 1,
			"ribbon: %d vertices with their attributes, the fall's rock, %d streams landing at its foot" % [arr[Mesh.ARRAY_VERTEX].size(), geo2.feet.size()])

	# ground questions route through Terrain to the source in use: water's
	# depth to the bottom asks it too
	var still := WaterBody.new()
	Terrain.use(ground)
	var depth := still.floor_depth_at(0.0, 100.0)
	var g_ok := absf(Terrain.height_at(0.0, 100.0) - ground.height_at(0.0, 100.0)) < 1e-6 and absf(depth - (0.0 - ground.height_at(0.0, 100.0))) < 1e-4
	Terrain.use(null)
	_check(g_ok and Terrain.height_at(0.0, 100.0) == Terrain.NO_GROUND and still.floor_depth_at(0.0, 100.0) == still.floor_depth,
			"Terrain answers from the source in use (none: no ground), and water's depth to the bottom asks it (%.2f m)" % depth)
	still.free()

	# with no ground, the water just lies level along its centreline
	var flat := RiverRibbons.build(rivers, null, FallGeometry.new())
	_check(flat.get_surface_count() == 1, "with no ground in use the ribbon still builds")
	_finish()
