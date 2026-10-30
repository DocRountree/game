class_name PlayerIntent
extends RefCounted
## What whoever controls a body wants it to do this frame: the player's
## keyboard and mouse (read()), and later an animal's or NPC's brain. The
## movement modes act on this, never on Input directly, so a locked or
## AI-driven body needs no special cases.

var move := Vector2.ZERO   ## Strafe (x) and forward (y), -1..1.
var rise := 0.0            ## Up (+) or down (-): Space / Shift.
var jump := false          ## Held: Space.
var sprint := false        ## Held: Ctrl.
var sneak := false         ## Held: Shift.


## The player's controls now (none at all if `locked`).
static func read(locked: bool) -> PlayerIntent:
	var i := PlayerIntent.new()
	if locked:
		return i
	i.move = Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	i.rise = Input.get_axis(&"dive", &"tread")
	i.jump = Input.is_action_pressed(&"tread")
	i.sprint = Input.is_action_pressed(&"sprint")
	i.sneak = Input.is_action_pressed(&"dive")
	return i
