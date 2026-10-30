class_name ContentRegistry
extends RefCounted
## Every content definition in the game, found by scanning src/data/ (and its
## folders) for resources once, on first use: items, species, biomes, boats,
## accessories, and whatever new kinds come (plants, animals, structures,
## NPC archetypes). Adding content is adding a .tres file: nothing lists it
## by hand. Ask by the definition's class name: all(&"AccessoryDef"),
## by_id(&"AccessoryDef", &"glasses").

const ROOT := "res://src/data/"

static var _by_class := {}   # StringName class -> Array[Resource]
static var _scanned := false


## Every definition of a class (its class_name), sorted by id (or path).
static func all(cls: StringName) -> Array:
	_scan()
	return _by_class.get(cls, [])


## The definition of a class with this id (its `id` property), or null.
static func by_id(cls: StringName, id: StringName) -> Resource:
	for r: Resource in all(cls):
		if r.get(&"id") == id:
			return r
	return null


## Forget what was found (tests that add definitions).
static func rescan() -> void:
	_scanned = false
	_by_class.clear()


static func _scan() -> void:
	if _scanned:
		return
	_scanned = true
	_walk(ROOT)
	for cls: StringName in _by_class:
		var list: Array = _by_class[cls]
		list.sort_custom(func(a: Resource, b: Resource) -> bool:
			return str(a.get(&"id") if a.get(&"id") != null else a.resource_path) < str(b.get(&"id") if b.get(&"id") != null else b.resource_path))


static func _walk(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_walk(dir + sub + "/")
	for f in d.get_files():
		var path := dir + f.trim_suffix(".remap")   # (exported builds list .tres.remap)
		if not path.ends_with(".tres"):
			continue
		var r := load(path)
		if r == null or r.get_script() == null:
			continue
		var cls: StringName = (r.get_script() as Script).get_global_name()
		if cls == &"":
			continue
		if not _by_class.has(cls):
			_by_class[cls] = []
		_by_class[cls].append(r)
