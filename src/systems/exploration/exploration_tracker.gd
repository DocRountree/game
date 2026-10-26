class_name ExplorationTracker
extends Node
## Remembers which parts of the world the player has seen, on a WorldGrid of
## cell_size squares, revealing everything within reveal_radius of the target.
## The player map will draw from explored cells; it records only, and never
## moves anyone (no fast travel).

@export var target: Node3D
@export var cell_size := 50.0       ## m per map cell.
@export var reveal_radius := 250.0  ## m seen around the target (larger from a boat or a height later).

var explored := {}                  ## Vector2i -> true

var _last_cell := Vector2i(2147483647, 0)


func _physics_process(_delta: float) -> void:
	if target == null:
		return
	var cell := WorldGrid.cell_of(target.global_position, cell_size)
	if cell == _last_cell:
		return
	_last_cell = cell
	reveal(target.global_position, reveal_radius)


## Mark everything within radius of a point explored; returns the new cells.
func reveal(at: Vector3, radius: float) -> Array[Vector2i]:
	var fresh: Array[Vector2i] = []
	for c in WorldGrid.cells_in_radius(at, cell_size, radius):
		if not explored.has(c):
			explored[c] = true
			fresh.append(c)
	if not fresh.is_empty():
		var events := get_node_or_null(^"/root/Events")
		if events:
			events.area_explored.emit(fresh)
	return fresh


func is_explored(at: Vector3) -> bool:
	return explored.has(WorldGrid.cell_of(at, cell_size))


func explored_area_km2() -> float:
	return explored.size() * cell_size * cell_size / 1e6


func to_dict() -> Dictionary:
	var cells := PackedInt32Array()
	for c: Vector2i in explored:
		cells.append(c.x)
		cells.append(c.y)
	return {"cell_size": cell_size, "cells": cells}


func from_dict(d: Dictionary) -> void:
	explored.clear()
	var cells: PackedInt32Array = d.get("cells", PackedInt32Array())
	for i in range(0, cells.size() - 1, 2):
		explored[Vector2i(cells[i], cells[i + 1])] = true
	_last_cell = Vector2i(2147483647, 0)
