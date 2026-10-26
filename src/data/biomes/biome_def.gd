@tool
class_name BiomeDef
extends Resource
## A habitat with its own community: open ocean, a coral reef, a kelp forest,
## a tidepool, a mangrove root maze, a river reach. Procedural generation will
## place biomes; spawners, sampling and the map will read them.

enum Medium { WATER, LAND, SHORE }

@export var id := &""
@export var display_name := ""
@export var medium := Medium.WATER
@export var depth_range := Vector2(0.0, 4000.0)   ## Water depth (m) where it occurs.
@export var map_color := Color(0.1, 0.25, 0.45)   ## Exploration map tint.
@export var species: Array[SpeciesDef] = []


## Species present at this depth and hour, for spawners and sampling.
func species_for(depth: float, hour: float, water: int) -> Array[SpeciesDef]:
	var out: Array[SpeciesDef] = []
	for s in species:
		if s.lives_in(water) and s.is_active_at(hour) \
				and depth >= s.depth_range.x and depth <= s.depth_range.y:
			out.append(s)
	return out
