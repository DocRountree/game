class_name WaterSample
extends RefCounted
## A snapshot of water at a place and time: what a sample jar holds, what the
## microscope will look at, and what fishing and scuba gear can read out.

var position := Vector3.ZERO
var body_kind := WaterBody.Kind.OCEAN
var depth := 0.0             ## Below the surface (m).
var salinity_ppt := 0.0
var temperature_c := 0.0
var turbidity := 0.0
var biome_id := &""
var day := 0
var time_of_day := 0.0
## Filled in by the microbe system later: species id -> relative abundance.
var organisms := {}


func to_dict() -> Dictionary:
	return {"position": [position.x, position.y, position.z], "body_kind": body_kind,
		"depth": depth, "salinity_ppt": salinity_ppt, "temperature_c": temperature_c,
		"turbidity": turbidity, "biome_id": String(biome_id), "day": day,
		"time_of_day": time_of_day, "organisms": organisms}
