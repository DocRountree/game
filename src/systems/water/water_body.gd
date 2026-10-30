@tool
class_name WaterBody
extends Node3D
## Base for anything you can float, swim or dive in: the ocean, a lake, a river.
## Physics, the camera and future systems (fishing, sampling, scuba) ask the
## static Water API, which finds the body at a point; they never need to know
## which kind of water it is.
##
## Subclasses override the virtual queries. The defaults describe flat, still,
## endless water at y = 0.

enum Kind { OCEAN, LAKE, RIVER }

@export var kind := Kind.OCEAN
## Where bodies overlap (a river mouth in the sea), the higher priority wins.
@export var priority := 0
@export var biome: BiomeDef

@export_group("Chemistry")
@export var salinity_ppt := 35.0         ## Seawater ~35, fresh water ~0.
@export var temperature_c := 18.0        ## At the surface.
@export_range(0.0, 1.0) var turbidity := 0.05   ## 0 clear .. 1 opaque; for visibility and diving.
@export var floor_depth := 4000.0        ## Where there's no ground (Terrain): depth of the bottom (m).

static var _bodies: Array[WaterBody] = []


static func all() -> Array[WaterBody]:
	return _bodies


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		_bodies.append(self)


func _exit_tree() -> void:
	_bodies.erase(self)


## Whether (x, z) lies inside this body's extent.
func contains_point(_x: float, _z: float) -> bool:
	return true


## Surface height (m) at (x, z). footprint > 0 low-passes the waves (a hull
## ignores wavelengths shorter than itself); ripple_radius >= 0 adds the
## interactive ripples averaged on a ring of that radius.
func surface_height(_x: float, _z: float, _footprint := 0.0, _ripple_radius := -1.0) -> float:
	return global_position.y if is_inside_tree() else position.y


## Interactive ripple height at (x, z), averaged on a ring of radius r.
func ripple_height(_x: float, _z: float, _r := 0.0) -> float:
	return 0.0


## Slope of the ripples (d height / dx, d height / dz), for wake shoves.
func ripple_slope(_x: float, _z: float) -> Vector2:
	return Vector2.ZERO


## How deep the water is to the bottom at (x, z) (m below its surface): down
## to the ground (Terrain), or floor_depth where there is none.
func floor_depth_at(x: float, z: float) -> float:
	var g := Terrain.height_at(x, z)
	if g == Terrain.NO_GROUND:
		return floor_depth
	return maxf(0.0, surface_height(x, z) - g)


## Current (m/s) at (x, z): rivers flow, tides and currents later.
func flow_at(_x: float, _z: float) -> Vector3:
	return Vector3.ZERO


## Temperature at a depth (m) below the surface. A simple thermocline.
func temperature_at(depth: float) -> float:
	return lerpf(temperature_c, 4.0, clampf(depth / 1000.0, 0.0, 1.0))


## Density (kg/m^3) for buoyancy: fresh water floats you less than the sea.
func density() -> float:
	return 1000.0 + salinity_ppt * (Water.RHO_SEA - 1000.0) / 35.0
