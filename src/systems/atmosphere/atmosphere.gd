@tool
class_name Atmosphere
extends Node
## Sky, sun, stars and time of day.
##
## Drives the single-scattering sky shader (after Sebastian Lague's Solar
## System) and keeps the sun light consistent with it: the light points where
## the sky draws the sun, and its colour is the sunlight that survives the trip
## through the same air, so sunsets light the world orange.
##
## Sun, stars and planets share one astronomical model on a fixed date: every
## day is the same winter-solstice day, so the clock alone sets their sky and it
## repeats exactly each day. Only the moon moves on from day to day. Latitude
## tilts the sky. World axes: +X east, -Z north (Godot's forward), +Y up.
##
## The clock runs fast: daylight (sunrise to sunset) lasts day_minutes of real
## time and the night night_minutes, with the speed easing between the two
## through twilight so sunsets don't rush by.

@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
@export var starfield: Starfield
@export var moon: Moon
@export var moonlight: DirectionalLight3D
@export var clouds: Clouds
@export_range(0.0, 24.0) var time_of_day := 12.0    ## Local mean solar time, hours.
@export_range(-89.0, 89.0) var latitude := 35.0     ## Degrees north.
@export var day_minutes := 15.0                     ## Real minutes from sunrise to sunset (0 = frozen).
@export var night_minutes := 5.0                    ## Real minutes from sunset to sunrise.
@export var sun_energy := 1.4
@export var moon_energy := 0.12                     ## Full moon light.

var day := 0   ## Days since the start; the moon's orbit follows it.

@export_group("Scattering")
# Lague's model with Earth-like proportions: his planets' atmospheres are 32%
# of their radius, which from the ground gives a milky zenith or weak sunsets.
# A thinner shell keeps the zenith blue and lets the horizon redden.
@export var wavelengths := Vector3(700, 530, 440)   ## nm for red, green, blue.
@export var scattering_strength := 30.0
@export var density_falloff := 4.3
@export var atmosphere_scale := 0.1                 ## Thickness relative to planet radius.
@export var intensity := 1.0
## Ozone absorption, relative to Earth's (keeps twilight blue rather than olive).
@export var ozone_strength := 2.2
## Haze (aerosol) scattering: the warm glow around a low sun. Not in Lague's model.
@export var mie_scattering := 2.5
@export var mie_falloff := 28.0                     ## Haze hugs the surface (air uses density_falloff).
@export_range(0.0, 0.99) var mie_g := 0.74         ## Forward-scattering strength.
@export var in_scattering_points := 16
@export_group("Lookup bake")
@export var lut_angles := 128                       ## Directions (most detail needed near the horizon).
@export var lut_heights := 64
@export var lut_steps := 32

var _coefficients := Vector3.ZERO
var _extinction := Vector3.ZERO
var _lut := PackedFloat32Array()
var _zenith_transmittance := Vector3.ONE
var _material: ShaderMaterial


func _ready() -> void:
	if world_environment and world_environment.environment and world_environment.environment.sky:
		_material = world_environment.environment.sky.sky_material as ShaderMaterial
	rebuild()
	_setup_clock()


## Recompute coefficients and the optical-depth lookup after changing scattering settings.
func rebuild() -> void:
	_coefficients = Vector3(pow(400.0 / wavelengths.x, 4.0), pow(400.0 / wavelengths.y, 4.0),
			pow(400.0 / wavelengths.z, 4.0)) * scattering_strength
	# Earth's ozone absorption relative to its blue Rayleigh scattering
	var ozone := Vector3(0.650, 1.881, 0.085) / 33.1 * _coefficients.z * ozone_strength
	_extinction = _coefficients + ozone
	_bake_lut()
	_zenith_transmittance = _transmittance(Vector3.UP)
	if _material:
		_material.set_shader_parameter("optical_depth_lut", _lut_texture())
		_material.set_shader_parameter("scattering_coefficients", _coefficients)
		_material.set_shader_parameter("ozone_absorption", _extinction - _coefficients)
		_material.set_shader_parameter("atmosphere_scale", atmosphere_scale)
		_material.set_shader_parameter("density_falloff", density_falloff)
		_material.set_shader_parameter("intensity", intensity)
		_material.set_shader_parameter("in_scattering_points", in_scattering_points)
		_material.set_shader_parameter("mie_scattering", mie_scattering)
		_material.set_shader_parameter("mie_falloff", mie_falloff)
		_material.set_shader_parameter("mie_g", mie_g)
	_update_sun()


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		var scrub := Input.get_axis(&"time_backward", &"time_forward") * 2.0   # hours per second
		var rate := clock_rate(time_of_day) if day_minutes > 0.0 else 0.0
		time_of_day += (rate + scrub) * delta
		while time_of_day >= 24.0:
			time_of_day -= 24.0
			day += 1
		while time_of_day < 0.0:
			time_of_day += 24.0
			day -= 1
	_update_sun()


# --- clock --------------------------------------------------------------------

var _sunrise := 7.0
var _sunset := 17.0
var _day_rate := 0.0     # game hours per real second while the sun is up
var _night_rate := 0.0   # ... in full night (sun 8+ degrees down)


## Game hours per real second at clock time t.
func clock_rate(t: float, night_rate := -1.0) -> float:
	if _day_rate == 0.0:
		_setup_clock()
	var nr := _night_rate if night_rate < 0.0 else night_rate
	return lerpf(_day_rate, nr, smoothstep(0.0, -0.14, sun_direction(t).y))


func sunrise() -> float:
	return _sunrise


func sunset() -> float:
	return _sunset


func _setup_clock() -> void:
	_sunrise = _horizon_crossing(-1.0)
	_sunset = _horizon_crossing(1.0)
	_day_rate = (_sunset - _sunrise) / (maxf(day_minutes, 0.01) * 60.0)
	# night speed: whatever makes sunset-to-sunrise last night_minutes, given the twilight easing
	var lo := _day_rate
	var hi := _day_rate * 1000.0
	for _i in 40:
		var mid := sqrt(lo * hi)
		if _night_seconds(mid) > night_minutes * 60.0:
			lo = mid
		else:
			hi = mid
	_night_rate = sqrt(lo * hi)


## Real seconds from sunset to sunrise for a given full-night speed.
func _night_seconds(night_rate: float) -> float:
	var span := _sunrise + 24.0 - _sunset
	var steps := 300
	var total := 0.0
	for i in steps:
		var t := _sunset + span * (i + 0.5) / steps
		total += span / steps / clock_rate(fmod(t, 24.0), night_rate)
	return total


## Clock time the sun crosses the horizon, searching from noon forward (1) or back (-1).
func _horizon_crossing(direction: float) -> float:
	var a := 12.0
	var b := 12.0
	while sun_direction(b).y > 0.0 and absf(b - 12.0) < 12.0:
		a = b
		b += 0.05 * direction
	for _i in 30:
		var m := (a + b) * 0.5
		if sun_direction(m).y > 0.0:
			a = m
		else:
			b = m
	return (a + b) * 0.5


## The one day that repeats forever: the 2026 winter solstice (Dec 21).
const DAY_JD := 2461395.5   # Planets.julian_date(2026, 355, 0.0)

var _planets_placed := false


## Julian date at clock time t (default now) on the fixed day (local mean time as UT).
func julian_date(t := -1.0) -> float:
	return DAY_JD + (time_of_day if t < 0.0 else t) / 24.0


## Local sidereal time (rad): the right ascension on the meridian at clock time t.
func local_sidereal_time(t := -1.0) -> float:
	# mean solar time: the mean sun crosses the meridian at noon
	var clock := time_of_day if t < 0.0 else t
	return Planets.mean_sun_longitude(julian_date(clock)) + (clock - 12.0) / 24.0 * TAU


## Rotation taking equatorial unit vectors (x to the March equinox, z to the
## north celestial pole) into the world (+X east, +Y up, -Z north).
func equatorial_to_world(t := -1.0) -> Basis:
	var lst := local_sidereal_time(t)
	var lat := deg_to_rad(latitude)
	return Basis(Vector3(-sin(lst), cos(lat) * cos(lst), sin(lat) * cos(lst)),
			Vector3(cos(lst), cos(lat) * sin(lst), sin(lat) * sin(lst)),
			Vector3(0.0, sin(lat), -cos(lat)))


## Unit vector toward the sun (true orbit, so noon drifts with the equation of time).
func sun_direction(t := -1.0) -> Vector3:
	return equatorial_to_world(t) * Planets.sun_direction(julian_date(t))


## Equatorial unit vector toward the moon. Unlike the sun it moves on every day.
func moon_equatorial() -> Vector3:
	var days := DAY_JD - 2451545.0 + day + time_of_day / 24.0
	return Planets.moon_direction(days, Planets.sun_ecliptic_longitude(julian_date()))


func moon_direction() -> Vector3:
	return equatorial_to_world() * moon_equatorial()


func moon_phase_text() -> String:
	return Moon.phase_name(moon_equatorial(), Planets.sun_direction(julian_date()))


func time_text() -> String:
	return "%02d:%02d  day %d" % [int(time_of_day), int(fmod(time_of_day, 1.0) * 60.0), day + 1]


func _update_sun() -> void:
	var dir := sun_direction()
	if _material:
		_material.set_shader_parameter("sun_direction", dir)
	if sun == null or not sun.is_inside_tree():
		return
	sun.global_basis = Basis.looking_at(-dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	# sunlight through the air: normalised so the overhead sun is white, sunsets stay warm
	var t := _transmittance(dir) / _zenith_transmittance
	var peak := maxf(t.x, maxf(t.y, t.z))
	var up := smoothstep(-0.03, 0.04, dir.y)    # the planet blocks the sun below the horizon
	sun.light_color = Color(t.x / peak, t.y / peak, t.z / peak) if peak > 0.0 else Color.BLACK
	sun.light_energy = sun_energy * clampf(peak, 0.0, 1.0) * up
	sun.shadow_enabled = up > 0.0
	var night := smoothstep(0.02, -0.16, dir.y)   # 0 by day, 1 from nautical twilight
	if starfield:   # stars come out from civil twilight (sun 0-10 degrees below the horizon)
		starfield.update_sky(equatorial_to_world(), night)
		if not _planets_placed:   # same day every day: planets never move among the stars
			_planets_placed = true
			starfield.update_planets(DAY_JD)
	var moon_dir := moon_direction()
	var moon_up := smoothstep(-0.02, 0.05, moon_dir.y)
	var illuminated := (1.0 - moon_dir.dot(dir)) * 0.5   # lit fraction from the sun-moon angle
	if moon:
		moon.update_sky(moon_dir, dir, night)
	if moonlight:
		moonlight.global_basis = Basis.looking_at(-moon_dir, Vector3.UP if absf(moon_dir.y) < 0.99 else Vector3.FORWARD)
		moonlight.light_energy = moon_energy * illuminated * moon_up * night
		moonlight.visible = moonlight.light_energy > 0.001
	if clouds:
		# Sunlight as it reaches the cloud layer, which still sees the sun for a
		# while after it sets at sea level. Stylised: keep the colour fully
		# saturated and dim it only gently (the real grazing light is nearly
		# black), so clouds glow orange and pink through the afterglow.
		var at_clouds := _transmittance_from(clouds.altitude, dir) / _zenith_transmittance
		var cloud_peak := maxf(at_clouds.x, maxf(at_clouds.y, at_clouds.z))
		var cloud_sun := (at_clouds / cloud_peak * sqrt(minf(cloud_peak, 1.0)) * sun_energy) if cloud_peak > 0.0 else Vector3.ZERO
		var day_amount := smoothstep(-0.12, 0.25, dir.y)
		var ambient := Vector3(0.20, 0.27, 0.40) * day_amount + Vector3(0.012, 0.014, 0.024) \
				+ Vector3(0.05, 0.055, 0.07) * illuminated * moon_up * night
		clouds.update_sky(dir, cloud_sun, ambient)


# --- optical-depth lookup (Lague's AtmosphereTexture.compute, on the CPU) -----
# u: view direction, from straight up (0) to straight down (1); v: height 0..1.

func _density(p: Vector2) -> Vector2:
	var h01 := (p.length() - 1.0) / atmosphere_scale
	return Vector2(exp(-h01 * density_falloff), exp(-h01 * mie_falloff)) * (1.0 - h01)


func _bake_lut() -> void:   # two channels: air, haze
	var top := 1.0 + atmosphere_scale
	_lut.resize(lut_angles * lut_heights * 2)
	for j in lut_heights:
		var origin := Vector2(0.0, lerpf(1.0, top, float(j) / (lut_heights - 1)))
		for i in lut_angles:
			var y := 1.0 - 2.0 * float(i) / (lut_angles - 1)
			var dir := Vector2(sqrt(maxf(0.0, 1.0 - y * y)), y)
			# distance to the outer edge of the atmosphere
			var b := origin.dot(dir)
			var far := -b + sqrt(maxf(0.0, b * b - (origin.length_squared() - top * top)))
			var depth := Vector2.ZERO
			for s in lut_steps:   # samples bunched toward the start, where the air is densest
				var x := (s + 0.5) / lut_steps
				depth += _density(origin + dir * (far * x * x)) * far * 2.0 * x / lut_steps
			# rays into the planet overflow; cap them (1e5 already blocks all light) so
			# texture filtering never multiplies infinity by zero
			_lut[(j * lut_angles + i) * 2] = minf(depth.x, 1e5)
			_lut[(j * lut_angles + i) * 2 + 1] = minf(depth.y, 1e5)


func _lut_texture() -> ImageTexture:
	var img := Image.create_from_data(lut_angles, lut_heights, false, Image.FORMAT_RGF, _lut.to_byte_array())
	return ImageTexture.create_from_image(img)


## Sunlight transmittance from a point height_m above the sea toward dir,
## including the planet blocking a sun below that point's horizon.
func _transmittance_from(height_m: float, dir: Vector3, planet_radius_m := 6400000.0) -> Vector3:
	var origin := Vector2(0.0, 1.0 + height_m / planet_radius_m)
	var d := Vector2(sqrt(maxf(0.0, 1.0 - dir.y * dir.y)), dir.y)
	var b := origin.dot(d)
	var c := origin.length_squared() - 1.0
	if b < 0.0 and b * b - c > 0.0:
		return Vector3.ZERO   # behind the planet
	var top := 1.0 + atmosphere_scale
	var far := -b + sqrt(maxf(0.0, b * b - (origin.length_squared() - top * top)))
	var depth := Vector2.ZERO
	for s in lut_steps:
		var x := (s + 0.5) / lut_steps
		depth += _density(origin + d * (far * x * x)) * far * 2.0 * x / lut_steps
	var haze := depth.y * mie_scattering * 1.1
	return Vector3(exp(-depth.x * _extinction.x - haze), exp(-depth.x * _extinction.y - haze),
			exp(-depth.x * _extinction.z - haze))


func _transmittance(dir: Vector3) -> Vector3:
	if _lut.is_empty():
		return Vector3.ONE
	var u := clampf(1.0 - (dir.y * 0.5 + 0.5), 0.0, 1.0) * (lut_angles - 1)   # from ground level, v = 0
	var i := mini(floori(u), lut_angles - 2)
	var air := lerpf(_lut[i * 2], _lut[i * 2 + 2], u - i)
	var haze := lerpf(_lut[i * 2 + 1], _lut[i * 2 + 3], u - i) * mie_scattering * 1.1
	return Vector3(exp(-air * _extinction.x - haze), exp(-air * _extinction.y - haze), exp(-air * _extinction.z - haze))
