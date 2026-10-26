class_name Water
## Static queries over every WaterBody in the world. Gameplay code asks here
## ("how deep is the water at this point, and what kind is it?") instead of
## holding a reference to a particular ocean or lake.

const G := 9.81
const RHO_SEA := 1025.0     ## Seawater density (kg/m^3), for tuning constants.
const NO_WATER := -INF      ## surface_height() where there is no water.


## The highest-priority body containing (x, z), or null on dry land.
static func body_at(x: float, z: float) -> WaterBody:
	var best: WaterBody = null
	for b in WaterBody.all():
		if (best == null or b.priority > best.priority) and b.contains_point(x, z):
			best = b
	return best


static func surface_height(x: float, z: float, footprint := 0.0, ripple_radius := -1.0) -> float:
	var b := body_at(x, z)
	return b.surface_height(x, z, footprint, ripple_radius) if b else NO_WATER


## How far below the surface a point is (negative = above it, -INF = no water).
static func depth_below_surface(pos: Vector3) -> float:
	return surface_height(pos.x, pos.z) - pos.y


## Everything a water sample (or a fishing spot, or a dive computer) needs.
static func sample_at(pos: Vector3) -> WaterSample:
	var b := body_at(pos.x, pos.z)
	if b == null:
		return null
	var s := WaterSample.new()
	s.position = pos
	s.body_kind = b.kind
	s.depth = maxf(0.0, b.surface_height(pos.x, pos.z) - pos.y)
	s.salinity_ppt = b.salinity_ppt
	s.temperature_c = b.temperature_at(s.depth)
	s.turbidity = b.turbidity
	s.biome_id = b.biome.id if b.biome else &""
	var clock := GameClock.current()
	if clock:
		s.day = clock.day
		s.time_of_day = clock.time_of_day
	return s
