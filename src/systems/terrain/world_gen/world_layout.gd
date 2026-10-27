class_name WorldLayout
extends RefCounted
## Where the land goes in a world, drawn from the seed. Laid out around a main
## continent (at the layout's origin): an archipelago scattered off one of its
## coasts, and a volcanic island chain trailing away from another, a big young
## volcano first, then ever smaller, older islands with open water between them.
## WorldBake later picks a spawn point offshore and shifts the world so the
## player starts there, at the world origin.


static func generate(config: WorldConfig) -> Array[Landmass]:
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed_for("layout")
	var out: Array[Landmass] = []

	var continent := Landmass.new()
	continent.kind = Landmass.Kind.CONTINENT
	continent.radius = rng.randf_range(10000.0, 12500.0)
	continent.peak = rng.randf_range(700.0, 1300.0)
	continent.aridity = rng.randf_range(0.25, 0.75)
	continent.coast_roughness = rng.randf_range(0.5, 0.9)
	continent.lake_count = rng.randi_range(4, 9)
	_add(out, continent, rng)
	_belts(continent, rng)

	var arch_dir := rng.randf() * TAU
	var arch := Landmass.new()
	arch.kind = Landmass.Kind.ARCHIPELAGO
	arch.center = Vector2.from_angle(arch_dir) * (continent.radius * 1.05 + 2500.0)
	arch.radius = 7000.0
	arch.peak = rng.randf_range(25.0, 110.0)
	arch.aridity = rng.randf_range(0.2, 0.8)
	arch.coast_roughness = rng.randf_range(0.5, 0.9)
	arch.lake_count = rng.randi_range(0, 1)
	_add(out, arch, rng)
	_scatter_islands(arch, arch_dir, rng)

	var volc_dir := arch_dir + deg_to_rad(rng.randf_range(110.0, 250.0))
	var volc := Landmass.new()
	volc.kind = Landmass.Kind.VOLCANIC_CHAIN
	volc.center = Vector2.from_angle(volc_dir) * (continent.radius * 1.1 + 3500.0)
	volc.radius = 9000.0
	volc.peak = rng.randf_range(450.0, 1000.0)
	volc.aridity = rng.randf_range(0.1, 0.6)
	volc.coast_roughness = rng.randf_range(0.2, 0.5)
	volc.lake_count = rng.randi_range(0, 1)
	_add(out, volc, rng)
	_chain(volc, volc_dir, rng)
	return out


static func _add(out: Array[Landmass], m: Landmass, rng: RandomNumberGenerator) -> void:
	m.id = out.size()
	m.seed = rng.randi()
	out.append(m)


# Mountain ranges across the continent, as gently bent lines.
static func _belts(m: Landmass, rng: RandomNumberGenerator) -> void:
	for _b in rng.randi_range(1, 2):
		var line := PackedVector2Array()
		var dir := Vector2.from_angle(rng.randf() * TAU)
		var side := Vector2(-dir.y, dir.x)
		var off := side * rng.randf_range(-0.35, 0.35) * m.radius
		var bend := rng.randf_range(-0.3, 0.3)
		for k in 9:
			var t := lerpf(-0.7, 0.7, k / 8.0)
			line.append(m.center + off + dir * t * m.radius + side * bend * m.radius * (1.0 - 4.0 * t * t / 1.96))
		m.belts.append(line)
	m.belt_width = rng.randf_range(2200.0, 3500.0)


# Many low islands, mostly small, in a band along the continent's coast.
static func _scatter_islands(m: Landmass, dir: float, rng: RandomNumberGenerator) -> void:
	var radial := Vector2.from_angle(dir)
	var along := Vector2(-radial.y, radial.x)
	for _k in rng.randi_range(18, 40):
		var u := rng.randf()
		var r := lerpf(120.0, 1100.0, u * u * u)
		var p := m.center + along * rng.randf_range(-6500.0, 6500.0) + radial * rng.randf_range(-2500.0, 3000.0)
		m.islands.append(Vector4(p.x, p.y, r, rng.randf_range(0.5, 1.0)))


# A hotspot trail: a big young volcano, then smaller, older islands, each
# separated from the last by open water.
static func _chain(m: Landmass, dir: float, rng: RandomNumberGenerator) -> void:
	var count := rng.randi_range(5, 8)
	var heading := dir + deg_to_rad(rng.randf_range(-60.0, 60.0))
	var turn := deg_to_rad(rng.randf_range(-12.0, 12.0))
	var p := m.center
	var r := rng.randf_range(1500.0, 2000.0)
	for k in count:
		var age := float(k) / maxf(count - 1, 1)              # 0 young .. 1 old
		m.islands.append(Vector4(p.x, p.y, r, lerpf(1.0, 0.4, age) * rng.randf_range(0.85, 1.05)))
		var next_r := maxf(r * rng.randf_range(0.65, 0.85), 220.0)
		var gap := rng.randf_range(500.0, 1400.0)
		heading += turn
		p += Vector2.from_angle(heading) * (r / 1.3 + next_r / 1.3 + gap) \
				+ Vector2.from_angle(heading + PI * 0.5) * rng.randf_range(-300.0, 300.0)
		r = next_r
