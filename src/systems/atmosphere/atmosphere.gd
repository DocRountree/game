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
## day is the same winter-solstice day, so the clock alone sets the sky and it
## repeats exactly each day. Latitude tilts the sky. World axes: +X east,
## -Z north (Godot's forward), +Y up.

@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
@export var starfield: Starfield
@export_range(0.0, 24.0) var time_of_day := 16.0    ## Local mean solar time, hours.
@export_range(-89.0, 89.0) var latitude := 35.0     ## Degrees north.
@export var hours_per_second := 0.0                 ## 0 = time stands still.
@export var sun_energy := 1.4

@export_group("Scattering")
# Lague's model with Earth-like proportions: his planets' atmospheres are 32%
# of their radius, which from the ground gives a milky zenith or weak sunsets.
# A thinner shell keeps the zenith blue and lets the horizon redden.
@export var wavelengths := Vector3(700, 530, 440)   ## nm for red, green, blue.
@export var scattering_strength := 20.0
@export var density_falloff := 4.3
@export var atmosphere_scale := 0.1                 ## Thickness relative to planet radius.
@export var intensity := 1.0
## Ozone absorption, relative to Earth's (keeps twilight blue rather than olive).
@export var ozone_strength := 1.0
## Haze (aerosol) scattering: the warm glow around a low sun. Not in Lague's model.
@export var mie_scattering := 1.5
@export var mie_falloff := 28.0                     ## Haze hugs the surface (air uses density_falloff).
@export_range(0.0, 0.99) var mie_g := 0.8          ## Forward-scattering strength.
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
		time_of_day = fposmod(time_of_day + (hours_per_second + scrub) * delta, 24.0)
	_update_sun()


## The one day that repeats forever: the 2026 winter solstice (Dec 21).
const DAY_JD := 2461395.5   # Planets.julian_date(2026, 355, 0.0)

var _planets_placed := false


## Julian date of the current moment on the fixed day (local mean time treated as UT).
func julian_date() -> float:
	return DAY_JD + time_of_day / 24.0


## Local sidereal time (rad): the right ascension on the meridian right now.
func local_sidereal_time() -> float:
	# mean solar time: the mean sun crosses the meridian at noon
	return Planets.mean_sun_longitude(julian_date()) + (time_of_day - 12.0) / 24.0 * TAU


## Rotation taking equatorial unit vectors (x to the March equinox, z to the
## north celestial pole) into the world (+X east, +Y up, -Z north).
func equatorial_to_world() -> Basis:
	var lst := local_sidereal_time()
	var lat := deg_to_rad(latitude)
	return Basis(Vector3(-sin(lst), cos(lat) * cos(lst), sin(lat) * cos(lst)),
			Vector3(cos(lst), cos(lat) * sin(lst), sin(lat) * sin(lst)),
			Vector3(0.0, sin(lat), -cos(lat)))


## Unit vector toward the sun (true orbit, so noon drifts with the equation of time).
func sun_direction() -> Vector3:
	return equatorial_to_world() * Planets.sun_direction(julian_date())


func time_text() -> String:
	return "%02d:%02d" % [int(time_of_day), int(fmod(time_of_day, 1.0) * 60.0)]


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
	if starfield:   # stars come out from civil twilight (sun 0-10 degrees below the horizon)
		starfield.update_sky(equatorial_to_world(), smoothstep(0.02, -0.16, dir.y))
		if not _planets_placed:   # same day every day: planets never move among the stars
			_planets_placed = true
			starfield.update_planets(DAY_JD)


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


func _transmittance(dir: Vector3) -> Vector3:
	if _lut.is_empty():
		return Vector3.ONE
	var u := clampf(1.0 - (dir.y * 0.5 + 0.5), 0.0, 1.0) * (lut_angles - 1)   # from ground level, v = 0
	var i := mini(floori(u), lut_angles - 2)
	var air := lerpf(_lut[i * 2], _lut[i * 2 + 2], u - i)
	var haze := lerpf(_lut[i * 2 + 1], _lut[i * 2 + 3], u - i) * mie_scattering * 1.1
	return Vector3(exp(-air * _extinction.x - haze), exp(-air * _extinction.y - haze), exp(-air * _extinction.z - haze))
