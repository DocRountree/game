class_name Landmass
extends RefCounted
## One piece of land in a world's layout: a continent, a volcanic island chain
## or an archipelago. WorldLayout draws these from the seed; WorldBake turns
## each into a land shape and an uplift rate (how fast the ground rises, which
## erosion then carves into mountains and valleys).

enum Kind { CONTINENT, VOLCANIC_CHAIN, ARCHIPELAGO }

var kind := Kind.CONTINENT
var id := 0
var center := Vector2.ZERO        ## World x, z (m).
var radius := 1000.0              ## Rough extent (m), for spacing and bounds.
var peak := 1000.0                ## Target highest point (m).
var aridity := 0.5                ## 0 wet .. 1 dry: scales rainfall and evaporation.
var coast_roughness := 0.5        ## How ragged the coastline is.
var lake_count := 0               ## How many lakes to try to place.
## Islands, as Vector4(x, z, radius, uplift): one per cone or island. Unused
## for continents.
var islands: Array[Vector4] = []
## Continents: mountain belts as polylines of world points, with a width (m).
var belts: Array[PackedVector2Array] = []
var belt_width := 3000.0
var seed := 0


func kind_name() -> String:
	return ["continent", "volcanic chain", "archipelago"][kind]
