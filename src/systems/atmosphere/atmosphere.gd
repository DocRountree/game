@tool
class_name Atmosphere
extends Node
## Sky, sun, moon and stars: the visuals of the time of day.
##
## Drives the single-scattering sky shader (after Sebastian Lague's Solar
## System) and keeps the sun light consistent with it: the light points where
## the sky draws the sun, and its colour is the sunlight that survives the trip
## through the same air, so sunsets light the world orange.
##
## Time comes from a GameClock and positions from Astronomy (sun, stars and
## on the world's fixed date; the moon and planets move on daily). This node only
## draws them, and answers sky questions for gameplay (is it night, how bright
## is the moon). Without a clock it shows noon on day 0.

@export var clock: GameClock
@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
@export var starfield: Starfield
@export var moon: Moon
@export var planets: PlanetLayer
@export var meteors: Meteors
@export var aurora: Aurora
@export var moonlight: DirectionalLight3D
@export var sun_energy := 1.4
@export_range(0.0, 1.0) var sunlight_desaturation := 0.5   ## How much of the low sun's colour is taken out of its light.
@export var moon_energy := 0.12                     ## Full moon light.
## The haze far land fades into (the environment's fog, half of it; the other
## half is the sky's own colour toward the horizon, so a sunset keeps its glow):
## blue by day, blue-violet at dusk, gone dark at night. The sky itself isn't fogged.
@export var haze_color := Color(0.48, 0.62, 0.88)
@export var haze_dusk_color := Color(0.36, 0.33, 0.58)

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
## High-altitude (stratospheric) aerosol layer. It still catches reddened
## sunlight after the sun has set below, and that light reaches you through
## blue sky: the pink and purple of twilight. Not in Lague's model.
@export var strat_scattering := 4.0
@export var strat_height := 0.15                    ## Layer centre, as a fraction of the atmosphere's thickness.
@export var strat_width := 0.07
@export_range(0.0, 0.99) var strat_g := 0.6
## Stylised rose-violet band above the sunset point during twilight.
@export var twilight_glow := 1.9
@export var twilight_tint := Color(0.72, 0.45, 0.98)
## How much the air changes from day to day (0 = every sunset identical).
## Each day draws its own haze, high aerosol and ozone, so sunsets range from
## clear golden ones to hazy orange or vivid pink-purple twilights.
@export_range(0.0, 1.0) var sunset_variety := 1.0
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
		_material.set_shader_parameter("strat_scattering", strat_scattering)
		_material.set_shader_parameter("strat_height", strat_height)
		_material.set_shader_parameter("strat_width", strat_width)
		_material.set_shader_parameter("strat_g", strat_g)
		_material.set_shader_parameter("twilight_glow", twilight_glow)
		_material.set_shader_parameter("twilight_tint", Vector3(twilight_tint.r, twilight_tint.g, twilight_tint.b))
	_update_sun()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint() and day() != _air_day:
		_vary_air(day())
	_update_sun()


# --- day-to-day variation --------------------------------------------------------

var _air_day := 0
var _base := {}


## Draw this day's air from the world seed: same day, same sunset.
func _vary_air(for_day: int) -> void:
	_air_day = for_day
	if _base.is_empty():
		_base = {"mie_scattering": mie_scattering, "mie_g": mie_g, "strat_scattering": strat_scattering,
				"ozone_strength": ozone_strength, "scattering_strength": scattering_strength,
				"twilight_glow": twilight_glow, "twilight_tint": twilight_tint}
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("sky:%d" % for_day)
	var v := sunset_variety
	mie_scattering = _base.mie_scattering * lerpf(1.0, rng.randf_range(0.45, 1.7), v)
	mie_g = clampf(_base.mie_g + v * rng.randf_range(-0.08, 0.1), 0.5, 0.9)
	# the high layer is usually faint, sometimes strong (after a far-off eruption)
	strat_scattering = _base.strat_scattering * lerpf(1.0, 0.2 + 2.3 * pow(rng.randf(), 1.5), v)
	ozone_strength = _base.ozone_strength * lerpf(1.0, rng.randf_range(0.8, 1.3), v)
	scattering_strength = _base.scattering_strength * lerpf(1.0, rng.randf_range(0.9, 1.15), v)
	twilight_glow = _base.twilight_glow * lerpf(1.0, rng.randf_range(0.3, 1.8), v)
	var tint: Color = _base.twilight_tint
	twilight_tint = Color.from_hsv(wrapf(tint.h + v * rng.randf_range(-0.06, 0.05), 0.0, 1.0), tint.s, tint.v)
	rebuild()


# --- sky queries ---------------------------------------------------------------

func time_of_day() -> float:
	return clock.time_of_day if clock else 12.0


func day() -> int:
	return clock.day if clock else 0


## Equatorial-to-world rotation at clock time t (default now).
func equatorial_to_world(t := -1.0) -> Basis:
	return Astronomy.equatorial_to_world(WorldConfig.current(), time_of_day() if t < 0.0 else t)


## Unit vector toward the sun at clock time t (default now).
func sun_direction(t := -1.0) -> Vector3:
	return Astronomy.sun_direction(WorldConfig.current(), time_of_day() if t < 0.0 else t)


func moon_direction() -> Vector3:
	return Astronomy.moon_direction(WorldConfig.current(), day(), time_of_day())


## Lit fraction of the moon's disc, 0 (new) .. 1 (full).
func moon_illumination() -> float:
	return Astronomy.moon_illumination(WorldConfig.current(), day(), time_of_day())


func moon_phase_text() -> String:
	return Astronomy.moon_phase_name(WorldConfig.current(), day())


## 0 by day, 1 from nautical twilight (sun 9+ degrees down): stars, fish that feed at night.
func night_amount() -> float:
	return smoothstep(0.02, -0.16, sun_direction().y)


func _update_sun() -> void:
	var dir := sun_direction()
	if _material:
		_material.set_shader_parameter("sun_direction", dir)
	if sun == null or not sun.is_inside_tree():
		return
	sun.global_basis = Basis.looking_at(-dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	# sunlight through the air: normalised so the overhead sun is white, sunsets
	# stay warm; a little less saturated than the air makes it, and as bright as
	# the light overall (not its reddest part), so a low sun gilds the land
	# rather than washing it red
	var t := _transmittance(dir) / _zenith_transmittance
	var peak := maxf(t.x, maxf(t.y, t.z))
	var lum := t.dot(Vector3(0.2126, 0.7152, 0.0722))
	var up := smoothstep(-0.03, 0.04, dir.y)    # the planet blocks the sun below the horizon
	var c := t / peak if peak > 0.0 else Vector3.ZERO
	c = c.lerp(Vector3.ONE * c.dot(Vector3(0.2126, 0.7152, 0.0722)), sunlight_desaturation)
	c /= maxf(c.x, maxf(c.y, maxf(c.z, 1e-6)))
	sun.light_color = Color(c.x, c.y, c.z) if peak > 0.0 else Color.BLACK
	sun.light_energy = sun_energy * clampf(lerpf(peak, lum, 0.5), 0.0, 1.0) * up
	sun.shadow_enabled = up > 0.0
	var night := night_amount()
	if world_environment and world_environment.environment:
		var day_ := smoothstep(-0.16, 0.1, dir.y)   # (still lit for a while after sunset)
		var haze := haze_dusk_color.lerp(haze_color, smoothstep(0.0, 0.3, dir.y))
		world_environment.environment.fog_light_color = haze * lerpf(0.03, 1.0, day_)
	if starfield:   # stars come out from civil twilight (sun 0-10 degrees below the horizon)
		starfield.update_sky(equatorial_to_world(), night)
	if planets:   # they wander from day to day, relative to the fixed sun
		planets.update_sky(Astronomy.planet_positions(WorldConfig.current(), day(), time_of_day()),
				equatorial_to_world(), night)
	if meteors:   # a night belongs to the day it began
		meteors.update_sky(night, day() if time_of_day() >= 12.0 else day() - 1)
	if aurora:   # a night belongs to the day it began
		aurora.update_sky(night, day() if time_of_day() >= 12.0 else day() - 1)
	var moon_dir := moon_direction()
	var moon_up := smoothstep(-0.02, 0.05, moon_dir.y)
	var illuminated := (1.0 - moon_dir.dot(dir)) * 0.5   # lit fraction from the sun-moon angle
	if moon:
		moon.update_sky(moon_dir, dir, night)
	if moonlight:
		moonlight.global_basis = Basis.looking_at(-moon_dir, Vector3.UP if absf(moon_dir.y) < 0.99 else Vector3.FORWARD)
		moonlight.light_energy = moon_energy * illuminated * moon_up * night
		moonlight.visible = moonlight.light_energy > 0.001


# --- optical-depth lookup (Lague's AtmosphereTexture.compute, on the CPU) -----
# u: view direction, from straight up (0) to straight down (1); v: height 0..1.

func _density(p: Vector2) -> Vector3:   # air, low haze, high aerosol layer
	var h01 := (p.length() - 1.0) / atmosphere_scale
	var s := (h01 - strat_height) / strat_width
	return Vector3(exp(-h01 * density_falloff), exp(-h01 * mie_falloff), exp(-s * s)) * (1.0 - h01)


func _bake_lut() -> void:   # channels: air, haze, high aerosol
	var top := 1.0 + atmosphere_scale
	_lut.resize(lut_angles * lut_heights * 4)
	for j in lut_heights:
		var origin := Vector2(0.0, lerpf(1.0, top, float(j) / (lut_heights - 1)))
		for i in lut_angles:
			var y := 1.0 - 2.0 * float(i) / (lut_angles - 1)
			var dir := Vector2(sqrt(maxf(0.0, 1.0 - y * y)), y)
			var depth := _optical_depth(origin, dir)
			# rays into the planet overflow; cap them (1e5 already blocks all light) so
			# texture filtering never multiplies infinity by zero
			var o := (j * lut_angles + i) * 4
			_lut[o] = minf(depth.x, 1e5)
			_lut[o + 1] = minf(depth.y, 1e5)
			_lut[o + 2] = minf(depth.z, 1e5)


## Optical depths from origin to the edge of the atmosphere along dir.
func _optical_depth(origin: Vector2, dir: Vector2) -> Vector3:
	var top := 1.0 + atmosphere_scale
	var b := origin.dot(dir)
	var far := -b + sqrt(maxf(0.0, b * b - (origin.length_squared() - top * top)))
	var depth := Vector3.ZERO
	for s in lut_steps:   # samples bunched toward the start, where the air is densest
		var x := (s + 0.5) / lut_steps
		depth += _density(origin + dir * (far * x * x)) * far * 2.0 * x / lut_steps
	return depth


func _extinguish(depth: Vector3) -> Vector3:
	var aerosol := depth.y * mie_scattering * 1.1 + depth.z * strat_scattering * 1.05
	return Vector3(exp(-depth.x * _extinction.x - aerosol), exp(-depth.x * _extinction.y - aerosol),
			exp(-depth.x * _extinction.z - aerosol))


func _lut_texture() -> ImageTexture:
	var img := Image.create_from_data(lut_angles, lut_heights, false, Image.FORMAT_RGBAF, _lut.to_byte_array())
	return ImageTexture.create_from_image(img)


func _transmittance(dir: Vector3) -> Vector3:
	if _lut.is_empty():
		return Vector3.ONE
	var u := clampf(1.0 - (dir.y * 0.5 + 0.5), 0.0, 1.0) * (lut_angles - 1)   # from ground level, v = 0
	var i := mini(floori(u), lut_angles - 2)
	var f := u - i
	return _extinguish(Vector3(lerpf(_lut[i * 4], _lut[i * 4 + 4], f), lerpf(_lut[i * 4 + 1], _lut[i * 4 + 5], f),
			lerpf(_lut[i * 4 + 2], _lut[i * 4 + 6], f)))
