@tool
class_name GameClock
extends Node
## Time of day and the day count, for everything that cares: the sky, creature
## activity, tides, logs and samples. The clock runs fast: daylight (sunrise to
## sunset) lasts day_minutes of real time and the night night_minutes, with
## the speed easing between the two through twilight so sunsets don't rush by.
##
## Every day is the same calendar day (see WorldConfig), so sunrise and sunset
## fall at the same clock times daily; only the moon moves on. A level has one
## clock and registers it with Game; find it with GameClock.current().

@export_range(0.0, 24.0) var time_of_day := 12.0    ## Local mean solar time, hours.
@export var day_minutes := 15.0                     ## Real minutes from sunrise to sunset (0 = frozen).
@export var night_minutes := 5.0                    ## Real minutes from sunset to sunrise.
@export var scrub_speed := 2.0                      ## Game hours per real second on [ and ].

var day := 0               ## Days since the start; the moon's orbit follows it.
var total_hours := 0.0     ## Game hours elapsed since the start (scrubbing included).
var real_seconds := 0.0    ## Real seconds the clock has run.

var _sunrise := 7.0
var _sunset := 17.0
var _day_rate := 0.0     # game hours per real second while the sun is up
var _night_rate := 0.0   # ... in full night (sun 8+ degrees down)


## The running level's clock (null in the editor or before a level loads).
static func current() -> GameClock:
	var game := WorldConfig._game()
	return game.clock if game else null


func _enter_tree() -> void:
	process_priority = -100   # tick before anything reads the time this frame
	if not Engine.is_editor_hint():
		var game := WorldConfig._game()
		if game:
			game.clock = self


func _exit_tree() -> void:
	var game := WorldConfig._game()
	if game and game.clock == self:
		game.clock = null


func _ready() -> void:
	_setup()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var scrub := Input.get_axis(&"time_backward", &"time_forward") * scrub_speed
	advance(((rate(time_of_day) if day_minutes > 0.0 else 0.0) + scrub) * delta)
	real_seconds += delta


## Move the clock by a number of game hours (negative goes back).
func advance(hours: float) -> void:
	time_of_day += hours
	total_hours += hours
	var start_day := day
	while time_of_day >= 24.0:
		time_of_day -= 24.0
		day += 1
	while time_of_day < 0.0:
		time_of_day += 24.0
		day -= 1
	if day != start_day and not Engine.is_editor_hint():
		var events := (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"Events")
		if events:
			events.day_changed.emit(day)


## Game hours per real second at clock time t.
func rate(t: float, night_rate := -1.0) -> float:
	if _day_rate == 0.0:
		_setup()
	var nr := _night_rate if night_rate < 0.0 else night_rate
	return lerpf(_day_rate, nr, smoothstep(0.0, -0.14, _sun_height(t)))


func sunrise() -> float:
	return _sunrise


func sunset() -> float:
	return _sunset


func is_daytime(t := -1.0) -> bool:
	return _sun_height(time_of_day if t < 0.0 else t) > 0.0


func time_text() -> String:
	return "%02d:%02d  day %d" % [int(time_of_day), int(fmod(time_of_day, 1.0) * 60.0), day + 1]


func to_dict() -> Dictionary:
	return {"time_of_day": time_of_day, "day": day, "total_hours": total_hours}


func from_dict(d: Dictionary) -> void:
	time_of_day = d.get("time_of_day", time_of_day)
	day = d.get("day", day)
	total_hours = d.get("total_hours", total_hours)


## Recompute sunrise, sunset and speeds (after changing durations or the world).
func _setup() -> void:
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


func _sun_height(t: float) -> float:
	return Astronomy.sun_direction(WorldConfig.current(), t).y


## Real seconds from sunset to sunrise for a given full-night speed.
func _night_seconds(night_rate: float) -> float:
	var span := _sunrise + 24.0 - _sunset
	var steps := 300
	var total := 0.0
	for i in steps:
		var t := _sunset + span * (i + 0.5) / steps
		total += span / steps / rate(fmod(t, 24.0), night_rate)
	return total


## Clock time the sun crosses the horizon, searching from noon forward (1) or back (-1).
func _horizon_crossing(direction: float) -> float:
	var a := 12.0
	var b := 12.0
	while _sun_height(b) > 0.0 and absf(b - 12.0) < 12.0:
		a = b
		b += 0.05 * direction
	for _i in 30:
		var m := (a + b) * 0.5
		if _sun_height(m) > 0.0:
			a = m
		else:
			b = m
	return (a + b) * 0.5
