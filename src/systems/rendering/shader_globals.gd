class_name ShaderGlobals
extends Node
## Sets the global shader uniforms every world shader shares
## (world_globals.gdshaderinc, declared in project.godot) once a frame: the
## world's clock, the main camera's position, the sun's direction and light,
## and the planet's radius (WorldConfig). A level holds one.

@export var sun: DirectionalLight3D

var _time := 0.0


func _ready() -> void:
	RenderingServer.global_shader_parameter_set(&"planet_radius", WorldConfig.current().planet_radius_m)


func _process(delta: float) -> void:
	_time += delta
	RenderingServer.global_shader_parameter_set(&"world_time", _time)
	var cam := get_viewport().get_camera_3d()
	if cam:
		RenderingServer.global_shader_parameter_set(&"world_view_pos", cam.global_position)
	if sun:
		RenderingServer.global_shader_parameter_set(&"sun_direction", sun.global_basis.z)
		RenderingServer.global_shader_parameter_set(&"sun_color",
				Vector3(sun.light_color.r, sun.light_color.g, sun.light_color.b) * sun.light_energy)
