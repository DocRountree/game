class_name PlayerMode
extends RefCounted
## One way the player moves: walking, swimming, climbing, mantling over an
## edge, driving a boat, flying. Exactly one is active (Player.mode, its id
## is Player.state); it runs the body each physics frame and decides itself
## when to hand over to another (Player.change_mode). Within a mode, `pose`
## says what the body is doing (treading, sinking, in the air ...), set by
## the mode as it runs, for the animation (CharacterRig) and the HUD.

var player: Player
var id: StringName
var pose: StringName


func _init(p: Player, mode_id: StringName) -> void:
	player = p
	id = mode_id


## Taking over (from the mode `from`, with whatever it handed on in `args`).
func enter(_from: StringName, _args: Dictionary) -> void:
	pass


## Handing over to another mode.
func exit() -> void:
	pass


func physics(_delta: float) -> void:
	pass


## A key or button for this mode; true if it used it.
func input(_event: InputEvent) -> bool:
	return false


## Turn the body (each frame): by default, to where the camera looks.
func orient(delta: float) -> void:
	player.face_camera(delta, 0.0)
