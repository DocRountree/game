class_name RiverRocks
extends RefCounted
## Rocks in the rivers' rapids: a few just upstream of each waterfall's lip
## (more, and bigger, in the mountains) and a scattering through the steep
## mountain stretches, set across the channel and standing a little out of the
## water. Faceted low stones, one multimesh for the lot.

const ABOVE_FALL := Vector2(3.0, 28.0)   ## How far upstream of a lip they lie (m).
const MOUNTAINS := 120.0                 ## Above this level (m), more and bigger.


static func build(world: WorldData) -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 911
	var xforms: Array[Transform3D] = []
	for r in world.rivers:
		var pts: PackedVector3Array = r.points
		var hw: PackedFloat32Array = r.half_width
		var arc := PackedFloat32Array([0.0])
		for k in range(1, pts.size()):
			arc.append(arc[k - 1] + Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length())
		for k in range(1, pts.size()):
			var drop := pts[k - 1].y - pts[k].y
			var run := arc[k] - arc[k - 1]
			var high := pts[k].y > MOUNTAINS
			if drop > 3.0 and drop > run:
				# the rapids above a fall's lip
				for i in (8 if high else 4):
					_place(xforms, rng, pts, hw, arc, arc[k - 1] - rng.randf_range(ABOVE_FALL.x, ABOVE_FALL.y), high)
			elif high and run > 0.0 and drop / run > 0.04 and rng.randf() < run / 40.0:
				# a steep mountain stretch
				_place(xforms, rng, pts, hw, arc, arc[k], true)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _stone()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Rocks"
	mmi.multimesh = mm
	return mmi


static func _place(xforms: Array[Transform3D], rng: RandomNumberGenerator, pts: PackedVector3Array,
		hw: PackedFloat32Array, arc: PackedFloat32Array, s: float, high: bool) -> void:
	if s < 0.0:
		return
	var j := arc.bsearch(s)
	j = clampi(j, 1, pts.size() - 1)
	var t := clampf((s - arc[j - 1]) / maxf(arc[j] - arc[j - 1], 0.01), 0.0, 1.0)
	var c := pts[j - 1].lerp(pts[j], t)
	var along := Vector2(pts[j].x - pts[j - 1].x, pts[j].z - pts[j - 1].z).normalized()
	var side := Vector2(-along.y, along.x) * hw[j] * rng.randf_range(-0.85, 0.85)
	var size := rng.randf_range(0.5, 1.4) * (1.5 if high else 1.0)
	var basis := Basis.from_euler(Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3)))
	basis = basis.scaled(Vector3(rng.randf_range(1.0, 1.7), rng.randf_range(0.6, 0.9), rng.randf_range(0.9, 1.3)) * size)
	# (standing a little out of the water)
	xforms.append(Transform3D(basis, Vector3(c.x + side.x, c.y - 0.15 * size, c.z + side.y)))


static func _stone() -> Mesh:
	var sp := SphereMesh.new()
	sp.radius = 0.5
	sp.height = 1.0
	sp.radial_segments = 7
	sp.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.4, 0.37)
	mat.roughness = 0.95
	sp.material = mat
	return sp
