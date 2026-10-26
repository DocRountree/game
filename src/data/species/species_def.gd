@tool
class_name SpeciesDef
extends Resource
## One kind of organism: a fish, a crab, a kelp, a diatom. Biomes list which
## species live in them; spawners, fishing gear, sample collection and the
## microscope all read the same definition.

enum Kind { FISH, INVERTEBRATE, PLANT, MICROBE }
enum Catch { ROD = 1, NET = 2, TRAP = 4, SAMPLE = 8 }   ## Bit flags.

@export var id := &""
@export var display_name := ""
@export var scientific_name := ""
@export var kind := Kind.FISH
@export_flags("Rod", "Net", "Trap", "Sample") var catch_methods := 0
@export_range(0.0, 1.0) var rarity := 0.5           ## 0 common .. 1 very rare.

@export_group("Habitat")
## Which waters it tolerates (WaterBody.Kind values).
@export_flags("Ocean", "Lake", "River") var waters := 1
@export var depth_range := Vector2(0.0, 50.0)         ## Metres below the surface.
@export var salinity_range := Vector2(30.0, 40.0)     ## ppt (freshwater ~0-0.5).
@export var temperature_range := Vector2(5.0, 30.0)   ## Celsius.
@export var active_hours := Vector2(0.0, 24.0)        ## Clock hours; start > end wraps midnight.

@export_group("Body")
@export var size_range := Vector2(0.1, 0.5)           ## Length in metres (microbes: ~1e-6..1e-4).
@export var school_size := Vector2i(1, 1)


func can_catch_with(method: Catch) -> bool:
	return catch_methods & method != 0


func lives_in(water: int) -> bool:
	return waters & (1 << water) != 0


func is_active_at(hour: float) -> bool:
	if active_hours.x <= active_hours.y:
		return hour >= active_hours.x and hour <= active_hours.y
	return hour >= active_hours.x or hour <= active_hours.y
