class_name FallData
extends RefCounted
## One waterfall of a river: a single steep drop the generator cut, sampled
## finely down its face (points first..last of its river, RiverData.riser
## 0 at the lip to 1 at the foot).

var first := 0                  ## Index of its lip's point in the river.
var last := 0                   ## Index of its foot's point.
var top := Vector3.ZERO         ## Its lip (x, water level, z).
var foot := Vector3.ZERO        ## Its foot.
var drop := 0.0                 ## m from lip to foot.
var half_width := 0.0           ## Of the water at its foot (m).
var direction := Vector3.FORWARD   ## Downstream across the ground (unit, y 0).


func _init(river: RiverData, lip: int, foot_index: int) -> void:
	first = lip
	last = foot_index
	top = river.points[lip]
	foot = river.points[foot_index]
	drop = top.y - foot.y
	half_width = river.half_width[foot_index]
	var d := foot - top
	d.y = 0.0
	direction = d.normalized() if d.length() > 1e-3 else Vector3.FORWARD
