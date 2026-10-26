# Minigames

One folder per minigame: `src/minigames/<name>/` holding its scene(s), scripts and
any assets only it uses. A minigame's root scene should:

- run standalone (F6 in the editor) for quick iteration,
- take what it needs from the world through exported properties or a setup
  method, not by reaching up the tree,
- emit a `finished(result)` signal instead of changing scenes itself.
