class_name WorldLayout
extends RefCounted
## Where the land goes in a world, drawn from the seed: usually a continent,
## one or two volcanic island chains and a few archipelagos, spread over the
## world square without touching, leaving open water around the origin where
## the player starts.

const SPAWN_CLEAR := 2500.0   ## Open water this far around the origin (m).
const EDGE_MARGIN := 2500.0   ## Land stays this far inside the world square.


static func generate(config: WorldConfig, world_size: float) -> Array[Landmass]:
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed_for("layout")
	var out: Array[Landmass] = []
	var half := world_size * 0.5 - EDGE_MARGIN
	var scale := world_size / 49152.0   # sizes below are tuned for a 49 km world

	var plan: Array[int] = []
	if rng.randf() < 0.85:
		plan.append(Landmass.Kind.CONTINENT)
	for _i in rng.randi_range(1, 2):
		plan.append(Landmass.Kind.VOLCANIC_CHAIN)
	for _i in rng.randi_range(1, 3):
		plan.append(Landmass.Kind.ARCHIPELAGO)

	for kind in plan:
		var m := Landmass.new()
		m.kind = kind
		m.id = out.size()
		m.seed = rng.randi()
		match kind:
			Landmass.Kind.CONTINENT:
				m.radius = rng.randf_range(8000.0, 12500.0) * scale
				m.peak = rng.randf_range(1400.0, 2600.0)
				m.aridity = rng.randf_range(0.2, 0.8)
				m.coast_roughness = rng.randf_range(0.4, 0.8)
				m.lake_count = rng.randi_range(4, 9)
			Landmass.Kind.VOLCANIC_CHAIN:
				m.radius = rng.randf_range(6000.0, 9000.0) * scale
				m.peak = rng.randf_range(900.0, 2200.0)
				m.aridity = rng.randf_range(0.1, 0.7)
				m.coast_roughness = rng.randf_range(0.2, 0.5)
				m.lake_count = rng.randi_range(0, 2)
			Landmass.Kind.ARCHIPELAGO:
				m.radius = rng.randf_range(4000.0, 7000.0) * scale
				m.peak = rng.randf_range(60.0, 320.0)
				m.aridity = rng.randf_range(0.2, 0.9)
				m.coast_roughness = rng.randf_range(0.5, 0.9)
				m.lake_count = rng.randi_range(0, 1)
		# find a free spot (the continent first, so it gets room)
		var placed := false
		for _try in 200:
			var c := Vector2(rng.randf_range(-half, half), rng.randf_range(-half, half))
			var r := m.radius
			if absf(c.x) + r > half + EDGE_MARGIN * 0.5 or absf(c.y) + r > half + EDGE_MARGIN * 0.5:
				continue
			if c.length() < r + SPAWN_CLEAR:
				continue
			var clear := true
			for o in out:
				if c.distance_to(o.center) < r + o.radius + 1500.0 * scale:
					clear = false
					break
			if clear:
				m.center = c
				placed = true
				break
		if not placed:
			continue
		_shape(m, rng, scale)
		out.append(m)
	return out


# Islands for chains and archipelagos; mountain belts for continents.
static func _shape(m: Landmass, rng: RandomNumberGenerator, scale: float) -> void:
	match m.kind:
		Landmass.Kind.CONTINENT:
			for _b in rng.randi_range(1, 2):
				var line := PackedVector2Array()
				var a := rng.randf() * TAU
				var dir := Vector2(cos(a), sin(a))
				var side := Vector2(-dir.y, dir.x)
				var off := side * rng.randf_range(-0.35, 0.35) * m.radius
				var bend := rng.randf_range(-0.3, 0.3)
				for k in 9:
					var t := lerpf(-0.75, 0.75, k / 8.0)
					line.append(m.center + off + dir * t * m.radius + side * bend * m.radius * (1.0 - 4.0 * t * t / 2.25))
				m.belts.append(line)
			m.belt_width = rng.randf_range(2200.0, 3800.0) * scale
		Landmass.Kind.VOLCANIC_CHAIN:
			# a hotspot trail: cones along a gentle arc, youngest (tallest) at one end
			var count := rng.randi_range(3, 6)
			var a := rng.randf() * TAU
			var dir := Vector2(cos(a), sin(a))
			var side := Vector2(-dir.y, dir.x)
			var bend := rng.randf_range(-0.25, 0.25)
			for k in count:
				var t := lerpf(-0.85, 0.85, float(k) / maxf(count - 1, 1))
				var age := float(k) / maxf(count - 1, 1)              # 0 young .. 1 old
				var p := m.center + dir * t * m.radius + side * (bend * m.radius * (1.0 - t * t) + rng.randf_range(-0.08, 0.08) * m.radius)
				var r := rng.randf_range(900.0, 1500.0) * scale * lerpf(0.9, 1.25, age)
				var uplift := lerpf(1.0, 0.35, age) * rng.randf_range(0.8, 1.1)
				m.islands.append(Vector4(p.x, p.y, r, uplift))
		Landmass.Kind.ARCHIPELAGO:
			var count := rng.randi_range(12, 32)
			for _k in count:
				var d := sqrt(rng.randf()) * m.radius * 0.9
				var a := rng.randf() * TAU
				var r := rng.randf_range(250.0, 1300.0) * scale * (1.0 - 0.5 * d / m.radius)
				m.islands.append(Vector4(m.center.x + cos(a) * d, m.center.y + sin(a) * d, r, rng.randf_range(0.5, 1.0)))
