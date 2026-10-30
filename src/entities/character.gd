class_name Character
extends CharacterBody3D
## A body CharacterRig can animate: the player now, NPCs and animals later.
## Its meshes hang on a "Model" child; whatever drives it keeps `pose` (what
## the body is doing: WALKING, AIRBORNE, SWIMMING, DIVING, TREADING, SINKING,
## CLIMBING, ON BOAT, FLYING), `climb_normal` (the rock's normal while
## climbing) and `head_under` up to date.

var pose := &""
var climb_normal := Vector3.BACK
var head_under := false

@onready var model: Node3D = $Model
