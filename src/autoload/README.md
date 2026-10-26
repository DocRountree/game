# Autoloads

Global services, registered in Project Settings, Globals, Autoload. Keep them
few and small; none owns gameplay.

| Autoload | Role |
|---|---|
| `Events` | Signal bus for world happenings that unrelated systems care about. Add a signal only when something emits it. |
| `Game` | The running world: its `WorldConfig`, level, `GameClock` and `Player`. Levels and the clock register themselves. |
| `Settings` | Player settings; for now the `QualitySettings` systems read when they build. |
| `Perf` | Smoothed frame time and render counts, for future dynamic resolution and LOD. |

Systems that belong to a level (an ocean, a clock) are scene nodes, not autoloads.
`@tool` scripts can't see autoloads in the editor, so shared lookups go through
static helpers (`WorldConfig.current()`, `QualitySettings.current()`,
`GameClock.current()`) that fall back to defaults there.
