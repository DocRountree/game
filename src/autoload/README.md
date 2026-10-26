# Autoloads

Global singletons, registered in Project Settings, Globals, Autoload.
Keep these few and small: game state, save/load, scene transitions, a signal bus.
Systems that belong to a level (like `Ocean`) are scene nodes, not autoloads.
