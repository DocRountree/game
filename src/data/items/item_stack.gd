class_name ItemStack
extends RefCounted
## Some number of one item, plus per-instance data (a jar's WaterSample, a
## fish's length, a tool's wear).

var item: ItemDef
var count := 1
var data := {}


func _init(def: ItemDef = null, amount := 1) -> void:
	item = def
	count = amount


func can_merge(other: ItemStack) -> bool:
	return other.item == item and data.is_empty() and other.data.is_empty() and count < item.max_stack


func to_dict() -> Dictionary:
	return {"item": item.resource_path if item else "", "count": count, "data": data}


static func from_dict(d: Dictionary) -> ItemStack:
	var path: String = d.get("item", "")
	if path == "" or not ResourceLoader.exists(path):
		return null
	var s := ItemStack.new(load(path), d.get("count", 1))
	s.data = d.get("data", {})
	return s
