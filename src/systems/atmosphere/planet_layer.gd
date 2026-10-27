@tool
class_name PlanetLayer
extends MultiMeshInstance3D
## The naked-eye planets as small coloured discs, drawn on the moon's layer:
## in front of the stars, behind the moon (which can pass over them).
## Unlike the stars they wander: Atmosphere moves them each frame from
## the day count, so over weeks they drift and loop among the constellations.
## Per instance: COLOR.rgb = colour; CUSTOM = (brightness, size px, 0, 0).

const RADIUS := 2450.0         ## Between the moon (2400 m) and the stars (2500 m).

## Same uniform boost over real brightness as the starfield, so a planet and a
## star of the same magnitude match.
@export var brightness := 1.5


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = Planets.BODIES.size()
	mm.custom_aabb = AABB(Vector3.ONE * -RADIUS, Vector3.ONE * RADIUS * 2.0)
	multimesh = mm
	custom_aabb = mm.custom_aabb


## Place the planets. positions from Astronomy.planet_positions; basis maps
## equatorial coordinates into the world; visibility 0 by day .. 1 at night.
func update_sky(positions: Array, equatorial_to_world: Basis, visibility: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or multimesh == null:
		return
	global_transform = Transform3D(equatorial_to_world, cam.global_position)
	for i in positions.size():
		var p: Array = positions[i]
		var dir: Vector3 = p[1]
		multimesh.set_instance_transform(i, Transform3D(Basis(), dir * RADIUS))
		multimesh.set_instance_color(i, p[3])
		multimesh.set_instance_custom_data(i, Color(brightness * Starfield._flux(p[2]), p[4], 0.0, 0.0))
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("visibility", visibility)
		mat.set_shader_parameter("pixel_angle", deg_to_rad(cam.fov) / maxf(get_viewport().get_visible_rect().size.y, 1.0))
	visible = visibility > 0.0
