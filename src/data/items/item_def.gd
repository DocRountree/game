@tool
class_name ItemDef
extends Resource
## Anything that can sit in a hand, a knapsack or a boat's hold: a rod, a net,
## a trap, a sample jar, a spyglass, a fish. Behaviour lives in systems that
## look at tags and stats; the definition is just data.
##
## Conventional tags: tool, rod, net, trap, sample_container, optic, wearable,
## catch, sample. Conventional stats: magnification, breath_seconds,
## catch_radius, capacity.

@export var id := &""
@export var display_name := ""
@export_multiline var description := ""
@export var icon: Texture2D
@export var max_stack := 1
@export var mass_kg := 0.5
@export var two_handed := false
@export var tags: Array[StringName] = []
@export var stats := {}


func has_tag(tag: StringName) -> bool:
	return tag in tags


func stat(name: StringName, default := 0.0) -> float:
	return stats.get(name, default)
