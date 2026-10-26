@tool
class_name StarCatalog
extends Resource
## The fixed night sky, built by tools/build_star_catalog.py.
##
## stars: three floats each: right ascension (rad), declination (rad), visual magnitude.
## deep_sky: six floats each: right ascension (rad), declination (rad), magnitude,
## major and minor diameter (arcmin), position angle (deg, north through east).

@export var source := ""
@export var stars := PackedFloat32Array()
@export var deep_sky := PackedFloat32Array()


func star_count() -> int:
	return stars.size() / 3


func deep_sky_count() -> int:
	return deep_sky.size() / 6
