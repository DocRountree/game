class_name Inventory
extends Node
## A fixed number of slots holding ItemStacks. The same component serves a
## hand (1 slot), the knapsack and a boat's hold; what may go where is up to
## an optional filter (e.g. only containers in a research station).

signal changed

@export var capacity := 8:
	set(value):
		capacity = maxi(value, 0)
		slots.resize(capacity)
@export var display_name := ""
## Only items with at least one of these tags fit (empty = anything).
@export var accepts_tags: Array[StringName] = []

var slots: Array[ItemStack] = []


func _init() -> void:
	slots.resize(capacity)


func accepts(item: ItemDef) -> bool:
	if accepts_tags.is_empty():
		return true
	for t in accepts_tags:
		if item.has_tag(t):
			return true
	return false


## Adds as much of the stack as fits; returns what's left over (null if all fit).
func add(stack: ItemStack) -> ItemStack:
	if stack == null or not accepts(stack.item):
		return stack
	for s in slots:
		if s and s.can_merge(stack):
			var moved := mini(stack.count, s.item.max_stack - s.count)
			s.count += moved
			stack.count -= moved
			if stack.count == 0:
				changed.emit()
				return null
	for i in capacity:
		if slots[i] == null:
			if stack.count <= stack.item.max_stack:
				slots[i] = stack
				changed.emit()
				return null
			slots[i] = ItemStack.new(stack.item, stack.item.max_stack)
			stack.count -= stack.item.max_stack
	changed.emit()
	return stack


## Takes the stack out of a slot.
func take(index: int) -> ItemStack:
	var s := slots[index]
	slots[index] = null
	if s:
		changed.emit()
	return s


func count_of(item: ItemDef) -> int:
	var n := 0
	for s in slots:
		if s and s.item == item:
			n += s.count
	return n


func free_slots() -> int:
	return slots.count(null)


func items() -> Array[ItemStack]:
	var out: Array[ItemStack] = []
	for s in slots:
		if s:
			out.append(s)
	return out


func total_mass() -> float:
	var m := 0.0
	for s in items():
		m += s.item.mass_kg * s.count
	return m


func to_dict() -> Dictionary:
	return {"slots": slots.map(func(s: ItemStack) -> Variant: return s.to_dict() if s else null)}


func from_dict(d: Dictionary) -> void:
	var saved: Array = d.get("slots", [])
	for i in capacity:
		slots[i] = ItemStack.from_dict(saved[i]) if i < saved.size() and saved[i] else null
	changed.emit()
