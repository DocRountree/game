@tool
class_name Moon
extends MeshInstance3D
## The moon: a sphere lit by the real sun direction, drawn as a camera-facing
## disc in the sky, so its phase is simply where the light falls. By day it
## adds to the sky (a pale disc); at night it covers the stars behind it.

const DISTANCE := 2400.0           ## Inside the camera's far plane.

@export var size_scale := 5.0      ## Angular size relative to the real moon (0.52 deg), which is only a few pixels.


func _ready() -> void:
	if mesh == null:
		mesh = QuadMesh.new()
	custom_aabb = AABB(Vector3.ONE * -1.0, Vector3.ONE * 2.0)


## Place the moon. moon_dir and sun_dir are world unit vectors; night is 0 by day, 1 at night.
func update_sky(moon_dir: Vector3, sun_dir: Vector3, night: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var z := -moon_dir                                   # disc faces the camera
	var x := (Vector3.UP if absf(z.y) < 0.99 else Vector3.FORWARD).cross(z).normalized()
	var y := z.cross(x)
	var size := deg_to_rad(0.52) * size_scale * DISTANCE
	global_transform = Transform3D(Basis(x * size, y * size, z), cam.global_position + moon_dir * DISTANCE)
	var mat := material_override as ShaderMaterial
	mat.set_shader_parameter("sun_local", Vector3(sun_dir.dot(x), sun_dir.dot(y), sun_dir.dot(z)))
	mat.set_shader_parameter("night", night)
	visible = moon_dir.y > -0.05


## Phase name from the sun and moon directions (waxing while the moon trails the sun eastward).
static func phase_name(moon_equatorial: Vector3, sun_equatorial: Vector3) -> String:
	var lit := (1.0 - moon_equatorial.dot(sun_equatorial)) * 0.5
	var waxing := sun_equatorial.cross(moon_equatorial).z > 0.0
	if lit < 0.03:
		return "new moon"
	if lit > 0.97:
		return "full moon"
	if absf(lit - 0.5) < 0.06:
		return "first quarter" if waxing else "last quarter"
	return ("waxing " if waxing else "waning ") + ("crescent" if lit < 0.5 else "gibbous")
