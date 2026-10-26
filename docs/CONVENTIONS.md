# Conventions

## Files and folders

- Group by **feature**, not by file type: a scene, its script, its shader and
  feature-specific assets live in the same folder (`src/entities/boat/`).
- `snake_case` for every file and folder name. Scene and script share a name
  (`boat.tscn` + `boat.gd`).
- Shared art and audio that several features use goes in `assets/<type>/`.
  Feature-only assets can sit next to the feature.
- Folders Godot should not scan (`docs/`, `tools/`, `native/`) contain a `.gdignore`.
- Commit the `.import` and `.uid` files Godot creates next to assets and
  scripts; they carry import settings and stable resource IDs. Never commit `.godot/`.

## GDScript

- Static typing everywhere (`var speed := 0.0`, `func f(x: float) -> void`).
- `class_name` for anything other code refers to by type.
- Order: signals, constants, exports, public vars, private vars (`_name`),
  `@onready`, built-in callbacks, public methods, private methods.
- Doc comments (`##`) on classes and exported properties; the editor shows them.
- Physics in `_physics_process`, visuals and camera in `_process`.
- Input goes through actions defined in the project input map, never raw keycodes.

## Scene communication

- **Call down, signal up.** A parent may call methods on its children; children
  emit signals and never reach up the tree by path.
- Cross-cutting singletons are rare and deliberate: `Ocean.instance` exists
  because every floating object needs it. New globals go in `src/autoload/`.
- Groups for "everything of a kind": `boats`, `ripple_sources`.

## Shaders

- Spatial and canvas shaders: `.gdshader` next to the feature.
- Compute shaders: `.glsl` with a `#[compute]` header, run through
  `RenderingDevice`. Always provide a fallback when no `RenderingDevice` exists
  (Compatibility renderer).

## Native code

C++ lives in `native/` as a GDExtension (see `native/README.md`). Move code there
only with profiler evidence, and keep the GDScript API identical so callers don't change.

## Tests

`tests/` holds headless tests runnable with `tools/run_tests.sh`. A test is a
`SceneTree` script that exits with code 0 on success. Add a check whenever a bug
is fixed in a system that has one.
