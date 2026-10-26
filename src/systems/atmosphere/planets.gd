class_name Planets
extends RefCounted
## Where the naked-eye planets are on a given date.
##
## Keplerian orbits from JPL's "Approximate Positions of the Planets" (E. M.
## Standish, Table 1, valid 1800-2050): good to a fraction of a degree, plenty
## for drawing the sky. Magnitudes: H + 5 log10(r * delta) + a linear phase term.

const OBLIQUITY := 0.40910   # 23.44 degrees

# name, colour (linear), disc size (px), absolute magnitude H, phase coefficient
# (mag per degree of phase angle), then a, e, I, L, long.peri, long.node at J2000
# and their rates per century (AU, unitless, degrees).
const BODIES := [
	["Mercury", Color(0.75, 0.70, 0.64), 2.6, -0.42, 0.038,
		0.38709927, 0.20563593, 7.00497902, 252.25032350, 77.45779628, 48.33076593,
		0.00000037, 0.00001906, -0.00594749, 149472.67411175, 0.16047689, -0.12534081],
	["Venus", Color(1.0, 0.97, 0.88), 4.0, -4.40, 0.013,
		0.72333566, 0.00677672, 3.39467605, 181.97909950, 131.60246718, 76.67984255,
		0.00000390, -0.00004107, -0.00078890, 58517.81538729, 0.00268329, -0.27769418],
	["Mars", Color(1.0, 0.52, 0.32), 3.0, -1.52, 0.016,
		1.52371034, 0.09339410, 1.84969142, -4.55343205, -23.94362959, 49.55953891,
		0.00001847, 0.00007882, -0.00813131, 19140.30268499, 0.44441088, -0.29257343],
	["Jupiter", Color(1.0, 0.92, 0.78), 3.6, -9.40, 0.005,
		5.20288700, 0.04838624, 1.30439695, 34.39644051, 14.72847983, 100.47390909,
		-0.00011607, -0.00013253, -0.00183714, 3034.74612775, 0.21252668, 0.20469106],
	["Saturn", Color(1.0, 0.88, 0.66), 3.2, -8.88, 0.0,
		9.53667594, 0.05386179, 2.48599187, 49.95424423, 92.59887831, 113.66242448,
		-0.00125060, -0.00050991, 0.00193609, 1222.49362201, -0.41897216, -0.28867794],
	["Uranus", Color(0.70, 0.90, 1.0), 2.4, -7.19, 0.0,
		19.18916464, 0.04725744, 0.77263783, 313.23810451, 170.95427630, 74.01692503,
		-0.00196176, -0.00004397, -0.00242939, 428.48202785, 0.40805281, 0.04240589],
]
const EARTH := [1.00000261, 0.01671123, -0.00001531, 100.46457166, 102.93768193, 0.0,
		0.00000562, -0.00004392, -0.01294668, 35999.37244981, 0.32327364, 0.0]


## Julian date for a calendar year, day of year (1 = Jan 1) and hour (UT).
static func julian_date(year: int, day_of_year: float, hour: float) -> float:
	var days := 365 * (year - 2000) + ceili((year - 2000) / 4.0) + (day_of_year - 1.0) + (hour - 12.0) / 24.0
	return 2451545.0 + days


## Heliocentric ecliptic position (AU) from Standish elements at T centuries past J2000.
static func _heliocentric(el: Array, offset: int, t: float) -> Vector3:
	var a: float = el[offset] + el[offset + 6] * t
	var e: float = el[offset + 1] + el[offset + 7] * t
	var inc := deg_to_rad(el[offset + 2] + el[offset + 8] * t)
	var mean_long: float = el[offset + 3] + el[offset + 9] * t
	var peri: float = el[offset + 4] + el[offset + 10] * t
	var node: float = el[offset + 5] + el[offset + 11] * t
	var m := deg_to_rad(fposmod(mean_long - peri + 180.0, 360.0) - 180.0)
	var ecc_anomaly := m + e * sin(m)
	for _i in 6:   # Kepler's equation, Newton steps
		ecc_anomaly -= (ecc_anomaly - e * sin(ecc_anomaly) - m) / (1.0 - e * cos(ecc_anomaly))
	var x := a * (cos(ecc_anomaly) - e)
	var y := a * sqrt(1.0 - e * e) * sin(ecc_anomaly)
	var w := deg_to_rad(peri - node)
	var o := deg_to_rad(node)
	var cw := cos(w)
	var sw := sin(w)
	var co := cos(o)
	var so := sin(o)
	var ci := cos(inc)
	return Vector3((cw * co - sw * so * ci) * x + (-sw * co - cw * so * ci) * y,
			(cw * so + sw * co * ci) * x + (-sw * so + cw * co * ci) * y,
			(sw * sin(inc)) * x + (cw * sin(inc)) * y)


static func _to_equatorial(v: Vector3) -> Vector3:
	return Vector3(v.x, v.y * cos(OBLIQUITY) - v.z * sin(OBLIQUITY), v.y * sin(OBLIQUITY) + v.z * cos(OBLIQUITY))


static func _to_ecliptic(v: Vector3) -> Vector3:
	return Vector3(v.x, v.y * cos(OBLIQUITY) + v.z * sin(OBLIQUITY), -v.y * sin(OBLIQUITY) + v.z * cos(OBLIQUITY))


## Equatorial unit vector toward the sun (x to the March equinox, z to the north pole).
static func sun_direction(jd: float) -> Vector3:
	return _to_equatorial(-_heliocentric(EARTH, 0, (jd - 2451545.0) / 36525.0)).normalized()


## The sun's ecliptic longitude (rad) at Julian date jd.
static func sun_ecliptic_longitude(jd: float) -> float:
	var earth := _heliocentric(EARTH, 0, (jd - 2451545.0) / 36525.0)
	return atan2(-earth.y, -earth.x)


## Equatorial unit vector toward the moon, `days` after J2000, placed relative to
## the sun's ecliptic longitude. Low-precision lunar theory: mean elongation D,
## the moon's mean anomaly M and argument of latitude F, plus the three largest
## periodic terms (equation of centre, evection, variation). Good to ~1 degree.
## The phase comes from D, so the moon goes round its 29.5-day cycle of phases.
static func moon_direction(days: float, sun_longitude: float) -> Vector3:
	var d := moon_mean_elongation(days)
	var m := deg_to_rad(134.963 + 13.064993 * days)
	var f := deg_to_rad(93.272 + 13.229350 * days)
	var lon := sun_longitude + d + deg_to_rad(6.289 * sin(m) + 1.274 * sin(2.0 * d - m) + 0.658 * sin(2.0 * d))
	var lat := deg_to_rad(5.128 * sin(f))
	return _to_equatorial(Vector3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat)))


## The moon's mean angle east of the sun (rad), `days` after J2000: it sets the phase.
static func moon_mean_elongation(days: float) -> float:
	return deg_to_rad(297.850 + 12.190749 * days)


## Mean longitude of the sun (rad), which sets mean solar time.
static func mean_sun_longitude(jd: float) -> float:
	var t := (jd - 2451545.0) / 36525.0
	return deg_to_rad(EARTH[3] + EARTH[9] * t + 180.0)


const MOON_RATE := 13.176   ## Degrees per day the moon moves against the stars.


## Planet positions at Julian date jd for a sky whose sun is frozen at sun_jd.
## The game repeats one calendar day for the sun but lets the days count on.
## Mercury and Venus never stray far from the sun, so they are turned about the
## ecliptic pole to keep their real angle from the frozen sun (otherwise they
## could end up at midnight). The outer planets keep their places among the
## stars, but run their orbits faster than real since epoch_jd: pace 0 is the
## real rate, 1 is about the moon's 13 degrees a day. The Earth keeps the real
## calendar, so their yearly retrograde loops stay gentle.
static func positions_relative_to_sun(jd: float, sun_jd: float, epoch_jd := 0.0, pace := 0.0) -> Array:
	var turn := sun_ecliptic_longitude(sun_jd) - sun_ecliptic_longitude(jd)
	var body_jd := PackedFloat64Array()
	if pace > 0.0:
		for body: Array in BODIES:
			var real_rate: float = body[14] / 36525.0   # mean longitude, degrees per day
			var speed := lerpf(1.0, MOON_RATE / real_rate, pace) if body[5] >= 1.0 else 1.0
			body_jd.append(epoch_jd + (jd - epoch_jd) * speed)
	var out := positions(jd, body_jd)
	for i in out.size():
		if BODIES[i][5] < 1.0:   # inner planet (semi-major axis < 1 AU)
			var e := _to_ecliptic(out[i][1]).rotated(Vector3(0, 0, 1), turn)
			out[i][1] = _to_equatorial(e).normalized()
	return out


## For each planet: [name, equatorial unit vector, magnitude, colour, disc size px].
static func positions(jd: float, body_jd := PackedFloat64Array()) -> Array:
	var t := (jd - 2451545.0) / 36525.0
	var earth := _heliocentric(EARTH, 0, t)
	var out := []
	for i in BODIES.size():
		var body: Array = BODIES[i]
		var tb := t if body_jd.is_empty() else (body_jd[i] - 2451545.0) / 36525.0
		var helio := _heliocentric(body, 5, tb)
		var geo := helio - earth
		var phase_angle := rad_to_deg((-helio).angle_to(-geo))   # sun-planet-earth
		var mag: float = body[3] + 5.0 * log(helio.length() * geo.length()) / log(10.0) + body[4] * phase_angle
		out.append([body[0], _to_equatorial(geo).normalized(), mag, body[1], body[2]])
	return out
