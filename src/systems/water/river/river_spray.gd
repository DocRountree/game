class_name RiverSpray
extends RefCounted
## Splash and mist where the waterfalls' water lands: one multimesh of
## camera-facing quads for all of them, animated entirely on the GPU
## (river_spray.gdshader), so it costs nothing on the CPU. Along each fall's
## foot, spread across the water's width, clumps of spray burst up and fall
## back over and over (higher and wider below a taller fall), and a few soft
## puffs of mist rise and drift away downstream, growing as they thin out; and
## on its face a little spray wherever a little fall lands on a ledge
## (RiverRibbons.Falls.ledges).

const SPLASH_SPACING := 0.7   ## Metres between splash clumps across a foot.
const MIST_SPACING := 3.0     ## Metres between mist puffs across a foot.


static func build(world: WorldData, ledges: Array = []) -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var xforms: Array[Transform3D] = []
	var custom: Array[Color] = []
	for r in world.rivers:
		var pts: PackedVector3Array = r.points
		var hw: PackedFloat32Array = r.half_width
		var ris: PackedFloat32Array = r.riser
		var k := 0
		while k < pts.size():
			if ris[k] < 0.0:
				k += 1
				continue
			var k0 := k
			while k + 1 < pts.size() and ris[k + 1] >= 0.0:
				k += 1
			var k1 := k
			k += 1
			var h := pts[k0].y - pts[k1].y
			if h < 0.8:
				continue
			var foot := pts[k1]
			var nxt := pts[mini(k1 + 2, pts.size() - 1)]
			var dir := Vector3(nxt.x - pts[k0].x, 0.0, nxt.z - pts[k0].z).normalized()
			var side := Vector3(-dir.z, 0.0, dir.x)
			var w := hw[k1] * 0.85
			# spray: clumps bursting up from the foot, all across it
			var n := maxi(int(2.0 * w / SPLASH_SPACING), 2)
			for i in n:
				var u := lerpf(-w, w, (i + rng.randf()) / n)
				var basis := Basis(side, Vector3.UP, dir)
				xforms.append(Transform3D(basis, foot + side * u + dir * rng.randf_range(0.2, 1.2)))
				custom.append(Color(rng.randf(), h, 0.0, rng.randf_range(0.8, 1.2)))
			# mist: a few soft puffs, rising and drifting away
			var m := maxi(int(2.0 * w / MIST_SPACING), 1)
			for i in m:
				var u := lerpf(-w, w, (i + rng.randf()) / m) * 0.7
				var basis := Basis(side, Vector3.UP, dir)
				xforms.append(Transform3D(basis, foot + side * u + dir * rng.randf_range(0.5, 2.0)))
				custom.append(Color(rng.randf(), h, 1.0, rng.randf_range(0.8, 1.2)))
	for l: Array in ledges:
		var dir := Vector3(l[1].x, 0.0, l[1].y)
		var basis := Basis(Vector3(-dir.z, 0.0, dir.x), Vector3.UP, dir)
		xforms.append(Transform3D(basis, l[0]))
		custom.append(Color(rng.randf(), l[2], 0.0, rng.randf_range(0.35, 0.55)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	mm.mesh = quad
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_custom_data(i, custom[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Spray"
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://src/systems/water/river/river_spray.gdshader")
	mat.render_priority = 2   # (over the river's water, which it rises from)
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 16.0   # (each quad flies about in the shader)
	return mmi
