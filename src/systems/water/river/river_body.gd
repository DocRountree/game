class_name RiverBody
extends WaterBody
## Every river in the world as one water body, from the generated
## centrelines (WorldData.rivers): the surface follows each river's level
## (falling downstream, blended smoothly between nearby reaches), the current
## runs along it, fastest mid-channel. RiverWater draws the water; this is
## what buoyancy, swimming and sampling see, and it keeps the shader's clock
## and sun in step.

const TILE := 128.0   ## Index tile side (m).
const SEG := 10       ## Floats per segment: a.x, a.z, b.x, b.z, level a, level b, hw a, hw b, speed a, speed b.

var material: ShaderMaterial

var _segments := PackedFloat32Array()
var _tiles: Array[PackedInt32Array] = []
var _per_side := 0
var _corner := Vector2.ZERO
var _sun: DirectionalLight3D
var _time := 0.0


func _init() -> void:
	kind = Kind.RIVER
	priority = 2
	salinity_ppt = 0.2
	temperature_c = 13.0
	turbidity = 0.08
	name = "RiverBody"


func setup(world: WorldData) -> void:
	_per_side = ceili(world.size / TILE)
	_corner = -Vector2.ONE * world.size * 0.5
	_tiles.resize(_per_side * _per_side)
	for t in _tiles.size():
		_tiles[t] = PackedInt32Array()
	for r in world.rivers:
		var p: PackedVector3Array = r.points
		var hw: PackedFloat32Array = r.half_width
		var sp: PackedFloat32Array = r.speed
		for k in p.size() - 1:
			if Vector2(p[k].x - p[k + 1].x, p[k].z - p[k + 1].z).length_squared() < 0.01:
				continue
			var i := _segments.size() / SEG
			_segments.append_array([p[k].x, p[k].z, p[k + 1].x, p[k + 1].z, p[k].y, p[k + 1].y, hw[k], hw[k + 1], sp[k], sp[k + 1]])
			var reach := maxf(hw[k], hw[k + 1]) * 2.0 + 4.0
			var lo := ((Vector2(minf(p[k].x, p[k + 1].x), minf(p[k].z, p[k + 1].z)) - Vector2.ONE * reach - _corner) / TILE).floor()
			var hi := ((Vector2(maxf(p[k].x, p[k + 1].x), maxf(p[k].z, p[k + 1].z)) + Vector2.ONE * reach - _corner) / TILE).floor()
			for y in range(clampi(int(lo.y), 0, _per_side - 1), clampi(int(hi.y), 0, _per_side - 1) + 1):
				for x in range(clampi(int(lo.x), 0, _per_side - 1), clampi(int(hi.x), 0, _per_side - 1) + 1):
					_tiles[y * _per_side + x].append(i)


func _ready() -> void:
	for b in WaterBody.all():
		if b is Ocean and b.sun:
			_sun = b.sun


func _process(delta: float) -> void:
	if material == null:
		return
	_time += delta
	material.set_shader_parameter("time", _time)
	if _sun:
		material.set_shader_parameter("sun_direction", _sun.global_basis.z)
		material.set_shader_parameter("sun_color", Vector3(_sun.light_color.r, _sun.light_color.g, _sun.light_color.b) * _sun.light_energy)


## The channel at a point: "r" (distance / half width from the nearest
## centreline), "surface" (water level, blended over nearby reaches),
## "flow" (Vector2 m/s, fastest mid-channel). Empty away from rivers.
func channel(x: float, z: float) -> Dictionary:
	var g := ((Vector2(x, z) - _corner) / TILE).floor()
	if g.x < 0 or g.y < 0 or g.x >= _per_side or g.y >= _per_side:
		return {}
	var p := Vector2(x, z)
	var best := INF
	var ws := 0.0
	var wl := 0.0
	var flow := Vector2.ZERO
	var wf := 0.0
	for i in _tiles[int(g.y) * _per_side + int(g.x)]:
		var o := i * SEG
		var a := Vector2(_segments[o], _segments[o + 1])
		var ab := Vector2(_segments[o + 2], _segments[o + 3]) - a
		var u := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var r := p.distance_to(a + ab * u) / lerpf(_segments[o + 6], _segments[o + 7], u)
		if r > 2.0:
			continue
		best = minf(best, r)
		var w := exp(-6.0 * r)
		ws += w
		wl += w * lerpf(_segments[o + 4], _segments[o + 5], u)
		wf += w
		flow += w * ab.normalized() * lerpf(_segments[o + 8], _segments[o + 9], u) * (1.0 - 0.5 * minf(r * r, 1.0))
	if ws == 0.0:
		return {}
	return {"r": best, "surface": wl / ws, "flow": flow / wf}


func contains_point(x: float, z: float) -> bool:
	var c := channel(x, z)
	return not c.is_empty() and c.r < 1.4 and Terrain.height_at(x, z) < c.surface


func surface_height(x: float, z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	var c := channel(x, z)
	return float(c.surface) if not c.is_empty() else -INF


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, surface_height(x, z) - Terrain.height_at(x, z))


func flow_at(x: float, z: float) -> Vector3:
	var c := channel(x, z)
	if c.is_empty() or c.r >= 1.4:
		return Vector3.ZERO
	var f: Vector2 = c.flow
	return Vector3(f.x, 0.0, f.y)
