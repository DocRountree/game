class_name Weather
extends Node
## Day-to-day weather: clear, normal (a smattering of cumulus) or overcast, with
## a thunderstorm on some overcast days. The schedule comes from the world seed,
## so a given day always has the same weather.
##
## Days come in blocks of 6-8. Each block has one overcast day with a normal day
## either side and clear days for the rest, so in the long run about 4 days in 7
## are clear, 2 normal and 1 overcast, and every overcast day is flanked by
## normal ones. One overcast day in STORM_CHANCE^-1 brings lightning.
##
## The look changes smoothly over the hours either side of midnight, so clouds
## form and dissolve rather than pop. Other systems read the blended values
## (cloud_coverage, cloud_fill, cloud_grey, sunlight) and storm_active().

enum Kind { CLEAR, NORMAL, OVERCAST }

const STORM_CHANCE := 0.1
const BLEND_HOURS := 2.0           ## Each side of midnight.
## Per kind: coverage (share of clouds forming), fill (fuller, longer-lived,
## bigger puffs), grey (darker cloud colour), sunlight (direct light factor).
const LOOKS := {
	Kind.CLEAR: [0.0, 0.0, 0.0, 1.0],
	Kind.NORMAL: [0.45, 0.0, 0.0, 1.0],
	Kind.OVERCAST: [1.0, 1.0, 0.65, 0.35],
}

@export var clock: GameClock
@export var clouds: Clouds

## Debug override (F7): -1 = the schedule; else a Kind, or 3 for a storm.
var override := -1
var cloud_coverage := 0.6
var cloud_fill := 0.0
var cloud_grey := 0.0
var sunlight := 1.0

var _cache := {}                   # day -> [kind, storm]


func _process(_delta: float) -> void:
	var day := clock.day if clock else 0
	var t := clock.time_of_day if clock else 12.0
	var look := _look(day)
	if t < BLEND_HOURS:
		look = _mix(_look(day - 1), look, 0.5 + 0.5 * t / BLEND_HOURS)
	elif t > 24.0 - BLEND_HOURS:
		look = _mix(look, _look(day + 1), 0.5 * (t - (24.0 - BLEND_HOURS)) / BLEND_HOURS)
	cloud_coverage = look[0]
	cloud_fill = look[1]
	cloud_grey = look[2]
	sunlight = look[3]
	if clouds:
		clouds.set_weather(cloud_coverage, cloud_fill, cloud_grey)


## The weather of a day (override included).
func kind_for(day: int) -> Kind:
	if override >= 0:
		return mini(override, Kind.OVERCAST) as Kind
	return schedule(day)[0]


## Whether there is a thunderstorm right now (the day whose weather dominates).
func storm_active() -> bool:
	if override >= 0:
		return override == 3
	var day := clock.day if clock else 0
	var t := clock.time_of_day if clock else 12.0
	if t < BLEND_HOURS * 0.5:
		day -= 1
	elif t > 24.0 - BLEND_HOURS * 0.5:
		day += 1
	return schedule(day)[1]


## [kind, storm] for a day, from the world seed.
func schedule(day: int) -> Array:
	if not _cache.has(day):
		_fill_block_containing(day)
	return _cache[day]


func _fill_block_containing(day: int) -> void:
	# blocks run forward from day 0 (block 0) and backward from day -1 (block -1)
	var k := 0 if day >= 0 else -1
	var start := 0
	while true:
		var b := _block(k)
		var length: int = b[0]
		var first := start if k >= 0 else start - length + 1
		if day >= first and day < first + length:
			for i in length:
				var d := first + i
				var kind := Kind.CLEAR
				if i == b[1]:
					kind = Kind.OVERCAST
				elif absi(i - b[1]) == 1:
					kind = Kind.NORMAL
				_cache[d] = [kind, i == b[1] and b[2]]
			return
		if k >= 0:
			start += length
			k += 1
		else:
			start -= length
			k -= 1


func _block(k: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldConfig.current().seed_for("weather-block:%d" % k)
	var length := rng.randi_range(6, 8)
	return [length, rng.randi_range(1, length - 2), rng.randf() < STORM_CHANCE]


func _look(day: int) -> Array:
	return LOOKS[kind_for(day)]


static func _mix(a: Array, b: Array, f: float) -> Array:
	var out := []
	for i in a.size():
		out.append(lerpf(a[i], b[i], f))
	return out


## Debug: cycle schedule -> clear -> normal -> overcast -> storm -> schedule.
func cycle_override() -> String:
	override = override + 1 if override < 3 else -1
	return ["weather: by schedule", "weather: clear", "weather: normal", "weather: overcast", "weather: storm"][override + 1]
