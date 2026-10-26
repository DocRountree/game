# Native code (GDExtension)

C++ for systems that profiling shows are too slow in GDScript. Godot does not
scan this folder (`.gdignore`); the built library and its `.gdextension` file go
into `res://bin/` when the first extension is added.

Setup when needed:

1. Add [godot-cpp](https://github.com/godotengine/godot-cpp) as a submodule at
   `native/godot-cpp`, on the branch matching the engine version (4.7).
2. Put sources in `native/src/`, with an `SConstruct` here that builds into `../bin/`.
3. Register classes in `register_types.cpp`. Keep the same method names as the
   GDScript they replace, so callers don't change.

Build output (`native/bin/`, object files) is git-ignored.
