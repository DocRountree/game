extends SceneTree
## What every headless test (tests/*_test.gd, run by tools/run_tests.sh)
## shares: a check that prints ok or FAIL, a count of failures, waiting a
## number of physics frames, and finishing with the exit code (0 = all
## passed). A test extends this and does its work from _initialize().

var _failures := 0


func _check(ok: bool, what: String) -> void:
	print(("  ok    " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _finish() -> void:
	print("\n%s: %d failure(s)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures else 0)


## Load a level and add it to the tree (for tests that need a running world).
func _load_world(path := "res://src/world/open_ocean/open_ocean.tscn") -> Node3D:
	var world: Node3D = load(path).instantiate()
	root.add_child(world)
	return world
