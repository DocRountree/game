class_name RiverSpray
extends RefCounted
## Splash and mist where the waterfalls' water lands: one multimesh of
## camera-facing quads for all of them, animated entirely on the GPU
## (river_spray.gdshader), so it costs nothing on the CPU. Wherever one of a
## fall's streams lands in the pool at its foot (RiverRibbons.Falls.feet),
## clumps of spray burst up across it and fall back over and over (higher
## below a taller fall), and a soft puff or two of mist rises and drifts away
## downstream, growing as it thins out; and on its face a little spray
## wherever a stream lands on a ledge (RiverRibbons.Falls.ledges).

const SPLASH_SPACING := 0.7   ## Metres between splash clumps across a foot.
const MIST_SPACING := 3.0     ## Metres between mist puffs across a foot.


static func build(ledges: Array = [], feet: Array = []) -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var xforms: Array[Transform3D] = []
	var custom: Array[Color] = []
	for f: Array in feet:
		var pos: Vector3 = f[0]
		var dir := Vector3(f[1].x, 0.0, f[1].y)
		var side := Vector3(-dir.z, 0.0, dir.x)
		var basis := Basis(side, Vector3.UP, dir)
		var h: float = f[2]
		var w: float = f[3]
		if h < 0.8:
			continue
		# spray: clumps bursting up all across where the stream lands
		var n := maxi(int(2.0 * w / SPLASH_SPACING), 1)
		for i in n:
			var u := lerpf(-w, w, (i + rng.randf()) / n) if n > 1 else rng.randf_range(-0.5, 0.5) * w
			xforms.append(Transform3D(basis, pos + side * u + dir * rng.randf_range(0.2, 1.0)))
			custom.append(Color(rng.randf(), h, 0.0, rng.randf_range(0.8, 1.2) * clampf(w / 1.2, 0.6, 1.2)))
		# mist: a soft puff or two, rising and drifting away
		var m := maxi(int(2.0 * w / MIST_SPACING), 1)
		for i in m:
			var u := lerpf(-w, w, (i + rng.randf()) / m) * 0.7
			xforms.append(Transform3D(basis, pos + side * u + dir * rng.randf_range(0.5, 2.0)))
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
