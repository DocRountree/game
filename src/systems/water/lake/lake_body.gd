class_name LakeBody
extends WaterBody
## A lake from the world bake: a flat surface at its current level. Terrain
## draws it, on the same water sheet as the rivers (so rivers flow into lakes
## without a seam); this is the water physics, fishing and sampling see.
## Terminal lakes (no outlet) are salty.

var level := 0.0
var rect := Rect2()
var lake_index := 0


func setup(lake: Dictionary, index: int) -> void:
	kind = Kind.LAKE
	priority = 1
	level = float(lake.level)
	rect = lake.rect
	lake_index = index
	salinity_ppt = 45.0 if lake.endorheic else 0.3
	temperature_c = 12.0
	turbidity = 0.12
	name = "Lake%d" % index


func contains_point(x: float, z: float) -> bool:
	if not rect.grow(200.0).has_point(Vector2(x, z)):
		return false
	var maps := Terrain.maps()
	return maps != null and absf(maps.lake_level_at(x, z) - level) < 0.5 and Terrain.height_at(x, z) < level


func surface_height(_x: float, _z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	return level


func floor_depth_at(x: float, z: float) -> float:
	return maxf(0.0, level - Terrain.height_at(x, z))
