# Assets

Imported art and audio shared across features.

| Folder | Contents |
|---|---|
| `models/` | `.glb` / `.blend` meshes and their textures |
| `textures/` | standalone textures (terrain, decals, UI images) |
| `audio/` | music and sound effects (`.ogg` for music, `.wav` for short effects) |
| `fonts/` | `.ttf` / `.otf` fonts |

Feature-only assets may live next to their feature in `src/` instead.
Commit the `.import` files Godot creates next to each asset.
Large binaries: set up Git LFS (see `.gitattributes`) before the first big batch.
