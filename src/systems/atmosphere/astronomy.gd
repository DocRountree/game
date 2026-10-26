class_name Astronomy
## Where things are in the local sky, as pure functions of the world (latitude
## and the repeating calendar day, from WorldConfig), the day count and the
## clock time. Atmosphere draws from it; the clock uses it to find sunrise and
## sunset; a telescope, star charts and navigation can use it the same way.
##
## World axes: +X east, -Z north (Godot's forward), +Y up. "Equatorial" unit
## vectors have x toward the March equinox and z toward the north celestial pole.

## Julian date at clock time t on the repeating day (local mean time as UT).
static func julian_date(world: WorldConfig, t: float) -> float:
	return world.day_jd + t / 24.0


## Local sidereal time (rad): the right ascension on the meridian at clock time t.
static func local_sidereal_time(world: WorldConfig, t: float) -> float:
	# mean solar time: the mean sun crosses the meridian at noon
	return Planets.mean_sun_longitude(julian_date(world, t)) + (t - 12.0) / 24.0 * TAU


## Rotation taking equatorial unit vectors into the world.
static func equatorial_to_world(world: WorldConfig, t: float) -> Basis:
	var lst := local_sidereal_time(world, t)
	var lat := deg_to_rad(world.latitude)
	return Basis(Vector3(-sin(lst), cos(lat) * cos(lst), sin(lat) * cos(lst)),
			Vector3(cos(lst), cos(lat) * sin(lst), sin(lat) * sin(lst)),
			Vector3(0.0, sin(lat), -cos(lat)))


## Unit vector toward the sun (true orbit, so noon drifts with the equation of time).
## The date never changes, so neither does the sun's path.
static func sun_direction(world: WorldConfig, t: float) -> Vector3:
	return equatorial_to_world(world, t) * Planets.sun_direction(julian_date(world, t))


## Equatorial unit vector toward the moon. Unlike the sun it moves on every day.
static func moon_equatorial(world: WorldConfig, day: int, t: float) -> Vector3:
	var days := world.day_jd - 2451545.0 + day + t / 24.0
	return Planets.moon_direction(days, Planets.sun_ecliptic_longitude(julian_date(world, t)))


static func moon_direction(world: WorldConfig, day: int, t: float) -> Vector3:
	return equatorial_to_world(world, t) * moon_equatorial(world, day, t)


## Planets on day `day` at clock time t: Mercury and Venus kept near the fixed
## sun, the outer planets wandering among the stars at the world's
## outer_planet_pace (see Planets.positions_relative_to_sun). Each: [name, equatorial unit vector,
## magnitude, colour, disc size px].
static func planet_positions(world: WorldConfig, day: int, t: float) -> Array:
	return Planets.positions_relative_to_sun(julian_date(world, t) + day, julian_date(world, t),
			world.day_jd, world.outer_planet_pace)


## Lit fraction of the moon's disc, 0 (new) .. 1 (full).
static func moon_illumination(world: WorldConfig, day: int, t: float) -> float:
	return (1.0 - moon_equatorial(world, day, t).dot(Planets.sun_direction(julian_date(world, t)))) * 0.5


static func moon_phase_name(world: WorldConfig, day: int, t: float) -> String:
	return Moon.phase_name(moon_equatorial(world, day, t), Planets.sun_direction(julian_date(world, t)))
