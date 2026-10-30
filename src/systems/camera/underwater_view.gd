class_name UnderwaterView
extends Node
## With the camera under the surface, the view closes in to a blue-green
## murk (the environment's fog, dimmed with the daylight); above it, the
## fog is put back as it was.

@export var camera: Camera3D
@export var environment: WorldEnvironment
@export var sun: DirectionalLight3D

var _air := {}


func _process(_delta: float) -> void:
	if camera == null or environment == null:
		return
	var env := environment.environment
	if _air.is_empty():
		_air = {"d": env.fog_density, "c": env.fog_light_color, "a": env.fog_aerial_perspective, "s": env.fog_sky_affect}
	var eye := camera.global_position
	var under := eye.y < Water.surface_height(eye.x, eye.z)
	var day := clampf(sun.light_energy, 0.05, 1.0) if sun else 1.0
	env.fog_density = 0.06 if under else _air.d
	env.fog_light_color = Color(0.02, 0.16, 0.2) * day if under else _air.c
	env.fog_aerial_perspective = 0.0 if under else _air.a
	env.fog_sky_affect = 1.0 if under else _air.s
